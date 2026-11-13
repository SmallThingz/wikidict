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
    @Test fun captionStackPreservesUnboundedHeightAndSubtractsOnlyFiniteBudget() {
        val unbounded = androidx.compose.ui.unit.Constraints(minWidth = 100, maxWidth = 100, minHeight = 12)
        for (top in listOf(0L, 26L, Int.MAX_VALUE.toLong(), Long.MAX_VALUE)) {
            val child = tableContentChildConstraints(unbounded, top)
            assertEquals(0, child.minWidth)
            assertEquals(100, child.maxWidth)
            assertEquals(0, child.minHeight)
            assertEquals(androidx.compose.ui.unit.Constraints.Infinity, child.maxHeight)
            assertFalse(child.hasBoundedHeight)
        }
        val bounded = unbounded.copy(maxHeight = 100)
        for ((top, expected) in listOf(0L to 100, 26L to 74, 100L to 0, 126L to 0, Long.MAX_VALUE to 0)) {
            val child = tableContentChildConstraints(bounded, top)
            assertEquals(0, child.minWidth)
            assertEquals(100, child.maxWidth)
            assertEquals(0, child.minHeight)
            assertEquals(expected, child.maxHeight)
            assertTrue(child.hasBoundedHeight)
        }
    }

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

class InlineTableImageTopTest {
    private class Wire {
        val out = java.io.ByteArrayOutputStream()
        fun byte(n: Int) { out.write(n) }
        fun short(n: Int) { byte(n); byte(n ushr 8) }
        fun int(n: Int) { repeat(4) { byte(n ushr (it * 8)) } }
        fun text(s: String) { val bytes = s.encodeToByteArray(); int(bytes.size); out.write(bytes) }
        fun length(unit: Int, n: Float) { byte(unit); int(n.toRawBits()) }
    }
    private fun fixture(version: Char = 'M', image: Boolean = false, align: Int? = null,
        cellStyle: (Wire.() -> Unit)? = null): ByteArray = Wire().apply {
        byte(68); byte(80); byte(82); byte(version.code); int(0)
        int(1); byte(2); text("Body"); text(""); text("")
        int(1); byte(5); byte(1); byte(0); int(0); byte(0); text("*"); text("")
        byte(1); byte(0); int(0); int(1); int(1)
        byte(0); short(1); short(1); byte(0)
        int(if (image) 1 else 0)
        if (image) {
            byte(1); byte(0); byte(0)
            text(""); text("Image-action"); text(""); text(""); text(""); text(""); text("")
            byte(0); byte(0); byte(0)
            byte(1); text("Speaker.svg"); byte(31); int(32); int(20); text(""); text("Speaker")
            byte(0); byte(0)
        }
        byte(0); byte(0)
        byte(if (cellStyle == null) 0 else 1); cellStyle?.invoke(this)
        if (version >= 'K') {
            byte(1); byte(0); byte(if (align == null) 1 else 3)
            byte(1); if (align != null) byte(align)
        } else byte(0)
        if (version >= 'J') byte(0)
        text(""); text(""); byte(0)
        if (version >= 'I') byte(0)
        if (version >= 'J') byte(0)
        if (version >= 'J') byte(0)
        repeat(4) { int(0) }
        int(if (image) 1 else 0)
        if (image) { text("Speaker.svg"); byte(0); text("Speaker") }
    }.out.toByteArray()
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "word", "language", "English", "en")
    private fun table(entry: Entry) = entry.sections.single().blocks.single().table!!
    private fun entry(image: InlineImage, classes: String = "", media: List<Media> =
        listOf(Media(image.file, "image", "Image"), Media("Voice.ogg", "audio", "Voice"))): Entry {
        val imageSpan = Span("link", "", "Image-action", classes = classes, image = image)
        val audio = Span("link", "Listen", "File:Voice.ogg", classes = "wikidict-media")
        val value = Table(emptyList(), listOf(listOf(Cell(listOf(imageSpan, Span("text", "Label")), false, 1, 1),
            Cell(listOf(audio), false, 1, 1))), style = TableStyle(display = TableDisplay.InlineBlock,
                verticalAlign = InlineBoxVerticalAlign.Top))
        return Entry("word", emptyList(), "language", "English", "en", listOf(Section(2, "Body",
            listOf(Block("list_item", 1, emptyList(), listPath = "*", table = value)))), emptyList(), media = media)
    }
    private fun marker(file: String) = "wikidict-media wikidict-media-file-" +
        file.encodeToByteArray().joinToString("") { "%02x".format(it.toInt() and 255) }

    @Test fun mInlineImageAndExternalTopDecodeWithoutWideningLegacyTables() {
        val bytes = fixture(image = true, align = 2)
        val decoded = read(bytes)
        val value = table(decoded)
        assertEquals(InlineBoxVerticalAlign.Top, value.style!!.verticalAlign)
        assertEquals("*", decoded.sections.single().blocks.single().listPath)
        assertEquals(InlineImage("Speaker.svg", 32, 20, "", "Speaker", border = true),
            value.rows.single().single().spans.single().image)
        assertEquals("Image-action", value.rows.single().single().spans.single().target)
        for (version in listOf('K', 'L')) {
            assertThrows(Exception::class.java) { read(fixture(version, image = true)) }
            assertThrows(Exception::class.java) { read(fixture(version, align = 2)) }
            for (alignment in listOf(null, 0, 1)) assertEquals(table(read(fixture('M', align = alignment))),
                table(read(fixture(version, align = alignment))))
        }
        assertThrows(Exception::class.java) { read(fixture(align = 3)) }
        for (size in bytes.indices) assertThrows(Exception::class.java) { read(bytes.copyOf(size)) }
        assertThrows(Exception::class.java) { read(bytes + byteArrayOf(0)) }
    }

    @Test fun cellTopFollowsMinimumTailAndKeepsEveryOtherReservedCellBitClosed() {
        val bytes = fixture(cellStyle = {
            byte(0xc7); byte(0); repeat(4) { length(1, 1.14f) }; byte(2); length(0, 17f); byte(0)
        })
        val style = table(read(bytes)).rows.single().single().style!!
        assertEquals(CellVerticalAlign.Top, style.verticalAlign)
        assertEquals(StyleLength(StyleLengthUnit.Px, 17f), style.minWidth)
        assertEquals(StyleLength(StyleLengthUnit.Em, 1.14f), style.padding!!.top)
        assertEquals(CellTextAlign.Right, style.textAlign)
        assertEquals(StyleBorder.None, style.border)
        assertNull(style.width); assertNull(style.borderEdges); assertNull(style.letterSpacing)
        for (version in listOf('H', 'J', 'K', 'L', 'M')) {
            val old = table(read(fixture(version, cellStyle = { byte(1); byte(0) }))).rows.single().single().style!!
            assertNull(old.verticalAlign)
            if (version != 'M') assertThrows(Exception::class.java) {
                read(fixture(version, cellStyle = { byte(128); byte(0) }))
            }
            for (reserved in if (version == 'M') listOf(16) else listOf(8, 16, 32)) assertThrows(Exception::class.java) {
                read(fixture(version, cellStyle = { byte(reserved); repeat(32) { byte(0) } }))
            }
        }
        assertEquals(CellVerticalAlign.Middle,
            table(read(fixture(cellStyle = { byte(128); byte(1) }))).rows.single().single().style!!.verticalAlign)
        assertThrows(Exception::class.java) { read(fixture(cellStyle = { byte(128); byte(2) })) }
        for (size in bytes.indices) assertThrows(Exception::class.java) { read(bytes.copyOf(size)) }
        assertThrows(Exception::class.java) { read(bytes + byteArrayOf(0)) }
    }

    @Test fun imageCatalogAndOptionalMediaMarkerMustIdentifyTheSameUniqueImage() {
        val naturalSpeaker = InlineImage("Loudspeaker.svg")
        assertEquals(InlineImagePixels(20f, 20f), inlineImagePixels(naturalSpeaker, 20, 20, 1f, "image/svg+xml"))
        assertNull(naturalSpeaker.widthPx); assertNull(naturalSpeaker.heightPx)
        val image = InlineImage("Speaker.svg", 32, 20, "", "Speaker", border = true, svgLanguage = "vi")
        val good = entry(image, marker(image.file))
        assertEquals(image, table(good).rows.single().first().spans.first().image)
        assertEquals(listOf("Speaker.svg", "Voice.ogg"), good.media.map { it.file })
        assertEquals("Image-action", table(good).rows.single().first().spans.first().target)
        assertNotNull(entry(image))
        val audio = Media("Voice.ogg", "audio", "Voice")
        val asset = Media(image.file, "image", "Speaker")
        val badCatalogs = listOf(listOf(audio), listOf(asset, asset, audio),
            listOf(asset.copy(kind = "audio"), audio), listOf(asset, audio, audio))
        for (catalog in badCatalogs) assertThrows(IllegalArgumentException::class.java) { entry(image, media = catalog) }
        for (classes in listOf(marker("Other.svg"), marker(image.file) + " wikidict-media-file-00",
            "wikidict-media wikidict-media-file-00")) assertThrows(IllegalArgumentException::class.java) {
            entry(image, classes, listOf(asset, audio, Media("Other.svg", "image", "Other")))
        }
    }

    @Test fun imageMapsPosterPoliciesAndDarkFiltersRemainOutsideInlineTableShape() {
        val image = InlineImage("Speaker.svg")
        assertThrows(IllegalArgumentException::class.java) { entry(image.copy(map = ImageMap(ImageMapDescription.None, emptyList()))) }
        assertThrows(IllegalArgumentException::class.java) { entry(image.copy(darkModeFilter = ImageDarkModeFilter.InvertHueRotate180)) }
        val poster = InlineImage("Object.stl", 4, 3, staticPoster = StaticPoster(StaticPosterPolicy.ThreeDStlV1,
            "3D", "0".repeat(40), "2026-01-01T00:00:00Z"))
        assertThrows(IllegalArgumentException::class.java) { entry(poster) }
    }

    @Test fun externalTopUsesWholeTableBoxAndParentStrutWithoutMovingMarkerBaseline() {
        for (display in listOf(null, TableDisplay.Table)) assertThrows(IllegalArgumentException::class.java) {
            TableStyle(display = display, verticalAlign = InlineBoxVerticalAlign.Top)
        }
        assertEquals(InlineTableLinePixels(60, 15, 0, 0), inlineTableLinePixels(20, 15f, 60, 58f,
            InlineBoxVerticalAlign.Top, 20, 15))
        assertEquals(InlineTableLinePixels(20, 15, 0, 0), inlineTableLinePixels(20, 15f, 5, 4f,
            InlineBoxVerticalAlign.Top, 20, 15))
        assertEquals(InlineTableLinePixels(63, 58, 0, 43), inlineTableLinePixels(20, 15f, 60, 58f,
            InlineBoxVerticalAlign.Baseline, 20, 15))
        assertEquals(InlineTableLinePixels(60, 32, 0, 17), inlineTableLinePixels(20, 15f, 60, 32f,
            InlineBoxVerticalAlign.Middle, 20, 15))
        assertEquals(InlineTableLinePixels(23, 18, 0, 0), inlineTableLinePixels(20, 15f, 5, 4f,
            InlineBoxVerticalAlign.Top, 22, 18))
        assertEquals(InlineTableLinePixels(0, 0, 0, 0), inlineTableLinePixels(0, 0f, 0, 0f,
            InlineBoxVerticalAlign.Top))
    }

    @Test fun mPreferredCellWidthPrecedesMinimumAndTopWithoutGrantingPrivateFields() {
        val bytes = fixture(cellStyle = {
            byte(0xe7); byte(0); repeat(4) { length(1, 1.14f) }; byte(2)
            byte(2); int(48f.toRawBits()); length(0, 17f); byte(0)
        })
        val style = table(read(bytes)).rows.single().single().style!!
        assertEquals(StyleWidth(StyleWidthUnit.Percent, 48f), style.width)
        assertEquals(StyleLength(StyleLengthUnit.Px, 17f), style.minWidth)
        assertEquals(CellVerticalAlign.Top, style.verticalAlign)
        assertNull(style.borderEdges); assertNull(style.letterSpacing)
        for (unit in 0..2) for (value in listOf(0f, 1.14f, 200f)) {
            val encoded = fixture(cellStyle = { byte(32); byte(unit); int(value.toRawBits()) })
            assertEquals(StyleWidth(StyleWidthUnit.entries[unit], value), table(read(encoded)).rows.single().single().style!!.width)
        }
        for (version in listOf('H', 'J', 'K', 'L')) assertThrows(Exception::class.java) {
            read(fixture(version, cellStyle = { byte(32); byte(2); int(48f.toRawBits()) }))
        }
        for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY)) assertThrows(Exception::class.java) {
            read(fixture(cellStyle = { byte(32); byte(0); int(value.toRawBits()) }))
        }
        assertThrows(Exception::class.java) { read(fixture(cellStyle = { byte(32); byte(3); int(0) })) }
        for (reserved in listOf(16)) assertThrows(Exception::class.java) {
            read(fixture(cellStyle = { byte(reserved); repeat(32) { byte(0) } }))
        }
        for (size in bytes.indices) assertThrows(Exception::class.java) { read(bytes.copyOf(size)) }
        assertThrows(Exception::class.java) { read(bytes + byteArrayOf(0)) }
    }

    @Test fun preferredPercentagesUseAllocatedTableWidthAndRetainIndependentMinimums() {
        fun cell(percent: Float, minimum: Float? = null) = Cell(listOf(Span("link", "x", "Target-$percent")),
            false, 1, 1, style = CellStyle(width = StyleWidth(StyleWidthUnit.Percent, percent),
                minWidth = minimum?.let { StyleLength(StyleLengthUnit.Px, it) }))
        fun widths(cells: List<Cell>, assigned: Int): List<Int> {
            val value = Table(emptyList(), listOf(cells)); val grid = tableGrid(value)
            return checkNotNull(inlineTableColumnWidths(grid, IntArray(cells.size) { 10 }, IntArray(cells.size) { 20 },
                0, 0, 900, authoredWidth = assigned,
                cellPreferences = tableCellWidthPreferences(grid, null, 0, 1f, 20f)))
        }
        assertEquals(listOf(40, 160), widths(listOf(cell(20f), cell(80f)), 200))
        assertEquals(listOf(20, 80), widths(listOf(cell(20f), cell(80f)), 100))
        assertEquals(listOf(200), widths(listOf(cell(48f)), 200))
        assertEquals(listOf(70, 130), widths(listOf(cell(20f, 70f), cell(80f)), 200))
        val excessive = cell(200f)
        val constrained = widths(listOf(excessive, cell(80f, 60f)), 200)
        assertEquals(200, constrained.sum()); assertTrue(constrained[1] >= 60)
        assertEquals(200f, excessive.style!!.width!!.value, 0f)
    }

    @Test fun laterRowColspanAndRowspanPreferencesShareOnePhysicalGrid() {
        fun cell(style: CellStyle? = null, cols: Int = 1, rows: Int = 1) =
            Cell(listOf(Span("text", "x")), false, cols, rows, style = style)
        val left = CellStyle(width = StyleWidth(StyleWidthUnit.Percent, 20f))
        val right = CellStyle(width = StyleWidth(StyleWidthUnit.Percent, 80f))
        val value = Table(emptyList(), listOf(listOf(cell(cols = 2)),
            listOf(cell(left, rows = 2), cell(right)), listOf(cell(right))))
        val grid = tableGrid(value)
        val widths = checkNotNull(inlineTableColumnWidths(grid, intArrayOf(80, 10, 10, 10), intArrayOf(80, 20, 20, 20),
            0, 0, 900, authoredWidth = 200, cellPreferences = tableCellWidthPreferences(grid, null, 0, 1f, 20f)))
        assertEquals(listOf(40, 160), widths)
        val pixels = checkNotNull(tablePixelLayout(grid, 1, 1, intArrayOf(10, 50, 10, 10), columnWidths = widths))
        assertEquals(200, pixels.cellWidth(2)); assertTrue(pixels.cellBottom(1, 2) - pixels.cellTop(1) >= 50)
        assertEquals(160, pixels.physicalCellLeft(0, 1, true))
        val em = cell(CellStyle(width = StyleWidth(StyleWidthUnit.Em, 1.14f)))
        val base = Table(emptyList(), listOf(listOf(em)))
        val changed = base.copy(rows = listOf(listOf(em.copy(spans = listOf(Span("text", "x", fontScale = .5f))))))
        val first = tableCellWidthPreferences(tableGrid(base), null, 0, 2f, 20f)
        assertEquals(23, first.single().pixels)
        assertEquals(first, tableCellWidthPreferences(tableGrid(changed), null, 0, 2f, 20f))
    }
}
