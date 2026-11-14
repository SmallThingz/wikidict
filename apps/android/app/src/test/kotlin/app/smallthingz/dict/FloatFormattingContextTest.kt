package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class FloatFormattingContextTest {
    @Test fun typedSectionHeadingStartsNativeSuffixAtItsRowBeforeLaterNativeBlocks() {
        val edge = StyleLength(StyleLengthUnit.Px, 0f)
        val zero = StyleEdges(edge, edge, edge, edge)
        val style = SectionHeadingStyle(ContainerStyle(margins = zero, padding = zero,
            border = ContainerBorder.None, clear = FigureClear.None, ownerFontScale = 1f,
            lineHeight = ContainerLineHeight.Normal, fontFamily = ContainerFontFamily.SansSerif),
            InlineFontSnapshot(fontScale = 1f, fontScaleBasis = FontScaleBasis.NormalBody, language = "th"), BidiResolvedDirection.Rtl)
        val prefix = Section(3, "", listOf(Block("paragraph", 0, listOf(Span("text", "Prefix")))))
        val companion = Block("heading", 0, listOf(Span("text", "Owner")), level = 3)
        val body = Block("paragraph", 0, listOf(Span("link", "Body", "body-action")))
        val section = Section(3, "Owner", listOf(companion, body), headingStyle = style)
        val trailing = Section(3, "", listOf(Block("container", 0, emptyList(), container = Container(emptyList(), ContainerStyle()))))
        val rows = readingRows(listOf(prefix, section, trailing))
        val start = rows.indexOfFirst { it.key == "heading-1" }
        assertEquals(listOf(start until rows.size), floatBodyRuns(rows, language = "Japanese"))
        assertEquals(listOf(1 until rows.size), floatBodyRuns(rows, BodyAdjoiningPolicy.Ordinary, "Japanese"))
        val folded = visibleReadingRows(rows, setOf("heading-1"))
        val foldedStart = folded.indexOfFirst { it.key == "heading-1" }
        assertEquals(listOf(foldedStart until folded.size), floatBodyRuns(folded, language = "Japanese"))
        assertSame(companion, folded[foldedStart].headingBlock)
        assertTrue(folded.none { it.key == "block-1-1" })
        val legacy = readingRows(listOf(prefix, section.copy(headingStyle = null), trailing))
        val nativeBlock = legacy.indexOfFirst { it.block?.container != null }
        assertEquals(listOf(nativeBlock until legacy.size), floatBodyRuns(legacy))
    }

    @Test fun whitespaceTypedHeadingOwnsItsRealBoxAndNullHasNoNativeTrigger() {
        val edge = StyleLength(StyleLengthUnit.Px, 0f)
        val zero = StyleEdges(edge, edge, edge, edge)
        val style = SectionHeadingStyle(ContainerStyle(margins = zero, padding = zero,
            border = ContainerBorder.None, clear = FigureClear.None, ownerFontScale = 0f,
            lineHeight = ContainerLineHeight.Multiplier(0f), fontFamily = ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif)),
            InlineFontSnapshot(fontScale = 0f, fontScaleBasis = FontScaleBasis.NormalBody, language = "th"), BidiResolvedDirection.Ltr)
        val companion = Block("heading", 0, listOf(Span("text", " ")), level = 3)
        val section = Section(3, " ", listOf(companion), headingStyle = style)
        val rows = readingRows(listOf(section))
        assertEquals(listOf(0..0), floatBodyRuns(rows))
        assertSame(companion, rows.single().headingBlock)
        assertTrue(floatBodyRuns(readingRows(listOf(section.copy(headingStyle = null)))).isEmpty())
    }

    @Test fun explicitBodyStartsAtFirstVisibleHeadingOrBlockWhileNullKeepsNativeSuffix() {
        val prefix = Block("paragraph", 0, listOf(Span("link", "Prefix", "prefix")))
        val enrolled = Block("container", 0, emptyList(), container = Container(emptyList(), ContainerStyle()))
        val rows = readingRows(listOf(Section(3, "First", listOf(prefix)), Section(3, "Later", listOf(enrolled))),
            bodyAdjoining = BodyAdjoiningPolicy.Ordinary)
        val legacyFirst = rows.indexOfFirst { it.block === enrolled }
        assertEquals(listOf(legacyFirst until rows.size), floatBodyRuns(rows))
        assertEquals(floatBodyRuns(rows), floatBodyRuns(rows, null, "English"))
        assertEquals(listOf(0 until rows.size), floatBodyRuns(rows, BodyAdjoiningPolicy.Ordinary, "English"))
        val folded = visibleReadingRows(rows, setOf("heading-0"))
        assertEquals(listOf(0 until folded.size), floatBodyRuns(folded, BodyAdjoiningPolicy.Ordinary, "English"))
        assertEquals(listOf("heading-0", "heading-1", "block-1-0"), folded.map { it.key })
        assertEquals(rows.map { it.key }, visibleReadingRows(rows, emptySet()).map { it.key })
        val invisibleHeading = readingRows(listOf(Section(3, "", listOf(prefix))),
            bodyAdjoining = BodyAdjoiningPolicy.Ordinary)
        assertEquals(listOf(1 until invisibleHeading.size),
            floatBodyRuns(invisibleHeading, BodyAdjoiningPolicy.Ordinary, "English"))
        assertTrue(floatBodyRuns(invisibleHeading).isEmpty())
    }

    @Test fun explicitBodyRetainsEmptySourceOwnersButDoesNotManufactureEmptySectionBodies() {
        val empty = readingRows(listOf(Section(3, "", emptyList())), bodyAdjoining = BodyAdjoiningPolicy.Ordinary)
        assertTrue(floatBodyRuns(empty, BodyAdjoiningPolicy.Ordinary).isEmpty())
        assertTrue(floatBodyRuns(emptyList(), BodyAdjoiningPolicy.Ordinary).isEmpty())
        val blank = Block("blank", 0, emptyList())
        val rows = readingRows(listOf(Section(3, "", listOf(blank))), bodyAdjoining = BodyAdjoiningPolicy.Ordinary)
        assertSame(blank, rows.last().block)
        assertEquals(listOf(1..1), floatBodyRuns(rows, BodyAdjoiningPolicy.Ordinary))
        assertTrue(floatBodyRuns(rows).isEmpty())
        val headingOnly = readingRows(listOf(Section(3, "Visible", emptyList())), bodyAdjoining = BodyAdjoiningPolicy.Ordinary)
        assertEquals(listOf(0..0), floatBodyRuns(headingOnly, BodyAdjoiningPolicy.Ordinary, "English"))
        assertTrue(floatBodyRuns(headingOnly).isEmpty())
    }

    private val images = listOf(
        InlineImage("Delegated-Mai-PNG.png", widthPx = 190L, heightPx = 248L, alt = ""),
        InlineImage("Delegated-Mai-JPEG.jpg", widthPx = 190L, heightPx = 296L, alt = ""),
    )
    private val captions = listOf("First retained caption", "Second retained caption")
    private val urls = listOf("https://example.invalid/figure/first", "https://example.invalid/figure/second")
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun edges(value: Float) = StyleEdges(px(value), px(value), px(value), px(value))
    private val noEdges = FigureBorderEdges(FigureBorderEdge.None, FigureBorderEdge.None,
        FigureBorderEdge.None, FigureBorderEdge.None)
    private fun captionPolicy(): FigureLinkPaint {
        val states = listOf("#3366cc", "#3056a9", "#233566", "#6a60b0", "#534fa3", "#353262")
            .mapIndexed { index, rgb -> FigureLinkState(rgb, index % 3 != 0) }
        return FigureLinkPaint(states[0], states[1], states[2], states[3], states[4], states[5], true,
            FigureFocusOutline(px(2f), FigureColor.Rgb("#ff0000"), px(2f),
                SignedContainerMargin(StyleLengthUnit.Px, -2f)))
    }

    private fun figure(index: Int, label: String): Figure {
        val media = FigureMediaLayout(FigureMediaStrut(1f, direction = BidiResolvedDirection.Ltr),
            InlineBoxVerticalAlign.Middle, positioning = ContainerPositioning.RelativeAuto,
            after = FigureMediaAfter(px(15f), px(11f), TableFloatSide.Right, px(6f),
                SignedContainerMargin(StyleLengthUnit.Px, -11f),
                FigureGraphicPaint(FigureMediaGraphic.MagnifyClipLtrV1)),
            focusOutline = FigureFocusOutline(px(2f), FigureColor.Rgb("#ff0000"), px(2f),
                SignedContainerMargin(StyleLengthUnit.Px, 0f)))
        val before = ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 15f)), height = px(11f),
            floatSide = TableFloatSide.Right, margins = StyleEdges(px(0f), px(0f), px(0f), px(3f)))
        return Figure(FigureContent.Image(Span("external_link", "", urls[index], image = images[index]),
            FigureSizingPolicy.RequestedFit), FigureFormat.Thumbnail, FigurePlacement.None, FigureClear.None,
            edges(0f), edges(3f), edges(6f), 1f, px(24f), FigureColor.Transparent, FigureBorder.None,
            FigureColor.Transparent, FigureBorder.None, FigureColor.NativeTheme, FigureColor.Rgb("#ffffff"),
            caption = listOf(Span("link", label, "caption-$index")),
            tableCaptionLayout = TableCaptionLayout(TableCollapse.Collapse, ContainerStyle(), noEdges, noEdges,
                media, captionBefore = before, captionLinkPaint = captionPolicy()))
    }

    private fun table(labels: List<String> = captions) = Table(emptyList(), images.indices.map { index ->
        listOf(Cell(emptyList(), false, 10, 1, blocks = listOf(
            Block("paragraph", 0, emptyList(), figure = figure(index, labels[index]))),
            style = CellStyle(padding = edges(0f))))
    }, style = TableStyle(floatSide = TableFloatSide.Right, clear = FigureClear.Right,
        margins = StyleEdges(px(0f), px(0f), px(16f), px(16f))))

    @Test fun paddingOnlyDelegatedFigureCellsUseContentWidthsWithoutChangingLegacyRoutes() {
        // Same semantic factory as the existing diagnostic device case; no View or media request.
        val delegated = table()
        assertTrue(nativeDelegatedFigureTable(delegated))
        assertFalse(tableHasComputedCellStyle(delegated))
        assertTrue(tableUsesContentWidths(delegated))
        assertTrue(tableUsesContentWidths(delegated, inherited = true))
        val plain = Table(emptyList(), listOf(listOf(Cell(listOf(Span("text", "ordinary")), false, 1, 1,
            style = CellStyle(padding = edges(0f))))))
        assertFalse(tableUsesContentWidths(plain))
        assertTrue(tableUsesContentWidths(plain, inherited = true)) // Existing scrollport/outer-cell inheritance.
        for (unit in TableWidthUnit.entries) {
            val legacy = plain.copy(geometry = TableGeometry(width = TableWidth(unit, 80)))
            assertFalse(tableUsesContentWidths(legacy))
            assertTrue(tableUsesContentWidths(legacy, inherited = true))
        }
        for (unit in StyleWidthUnit.entries) {
            val authored = plain.copy(style = TableStyle(width = StyleWidth(unit, 50f)))
            assertFalse(tableUsesContentWidths(authored))
            assertTrue(tableUsesContentWidths(authored, inherited = true))
        }
        val computed = plain.copy(rows = listOf(listOf(plain.rows.single().single().copy(
            style = CellStyle(minWidth = px(30f))))))
        assertTrue(tableUsesContentWidths(computed))
        val inline = plain.copy(style = TableStyle(display = TableDisplay.InlineTable))
        assertFalse(nativeDelegatedFigureTable(inline))
        assertFalse(tableUsesContentWidths(inline))
        val captioned = delegated.copy(caption = listOf(Span("text", "ordinary caption")))
        assertFalse(nativeDelegatedFigureTable(captioned))
        assertFalse(tableUsesContentWidths(captioned))
        // Stored spans remain 10; two full-width rows have only the boundaries 0 and 10.
        assertEquals(listOf(10, 10), delegated.rows.map { it.single().colspan })
        val compressed = tableGrid(delegated)
        assertEquals(1, compressed.columns)
        assertEquals(listOf(1, 1), compressed.cells.map { it.colspan })
        assertEquals(listOf("caption-0", "caption-1"), delegated.rows.map {
            it.single().blocks!!.single().figure!!.caption.single().target
        })
    }

    @Test fun delegatedContentWidthsRetainIntrinsicMinimumAndAuthoredTableRequests() {
        val source = table()
        val grid = tableGrid(source)
        val natural = checkNotNull(tableRenderMetrics(source, 1, 10, 40, 1f, containerFontPixels = 20f))
        val preferences = tableCellWidthPreferences(grid, natural.style?.cellInsets, 0, 1f, 20f)
        fun measured(available: Int, requested: Int? = null) = checkNotNull(inlineTableMetrics(
            natural, grid, intArrayOf(220, 210), intArrayOf(380, 400), available, requested, preferences))
        val wide = measured(800)
        assertEquals(400, wide.width)
        val full = grid.cells.first()
        assertEquals(400, wide.cellWidth(full.column, full.colspan))
        assertEquals(220, measured(180).width) // Real grid remains wider than its scrolling viewport.
        assertEquals(300, measured(800, 300).width)
        assertEquals(220, measured(800, 100).width) // An authored request cannot erase a content minimum.
        assertEquals(wide, measured(800))
        val styled = source.copy(style = source.style!!.copy(width = StyleWidth(StyleWidthUnit.Percent, 50f)),
            geometry = TableGeometry(width = TableWidth(TableWidthUnit.Px, 900)))
        assertTrue(tableUsesContentWidths(styled))
        assertEquals(StyleWidth(StyleWidthUnit.Percent, 50f), styled.style!!.width)
        assertEquals(TableWidth(TableWidthUnit.Px, 900), styled.geometry!!.width)
        assertEquals(300, measured(600, 300).width) // Resolved percentage uses the existing containing-width route.
        // A split third row introduces a meaningful interior boundary. Both original
        // stored 10 cells now span two actual columns; the split stored 5 cells span one.
        val spanning = source.copy(rows = source.rows + listOf(listOf(
            source.rows[0].single().copy(colspan = 5), source.rows[1].single().copy(colspan = 5))))
        assertTrue(tableUsesContentWidths(spanning))
        val spanGrid = tableGrid(spanning)
        assertEquals(2, spanGrid.columns)
        assertEquals(listOf(2, 2, 1, 1), spanGrid.cells.map { it.colspan })
        assertEquals(listOf(0, 0, 0, 1), spanGrid.cells.map { it.column })
        val spanNatural = checkNotNull(tableRenderMetrics(spanning, 1, 10, 40, 1f, containerFontPixels = 20f))
        val spanPreferences = tableCellWidthPreferences(spanGrid, spanNatural.style?.cellInsets, 0, 1f, 20f)
        fun spanMeasured(available: Int, requested: Int? = null) = checkNotNull(inlineTableMetrics(
            spanNatural, spanGrid, intArrayOf(220, 210, 80, 90), intArrayOf(380, 400, 120, 200),
            available, requested, spanPreferences))
        val spanWide = spanMeasured(800)
        assertEquals(400, spanWide.width)
        assertEquals(400, spanWide.cellWidth(0, 2))
        assertEquals(spanWide.cellWidth(0, 2), spanWide.cellWidth(0, 1) + spanWide.cellWidth(1, 1))
        assertTrue(spanWide.cellWidth(0, 1) >= 80)
        assertTrue(spanWide.cellWidth(1, 1) >= 90)
        assertEquals(220, spanMeasured(180).width)
        assertEquals(300, spanMeasured(800, 300).cellWidth(0, 2))
        assertEquals(220, spanMeasured(800, 100).width)
        assertEquals(spanWide, spanMeasured(800))
    }

    @Test fun delegatedCellWidthPreferencesKeepPixelsPercentagesAndSpanningGeometry() {
        val source = table()
        val first = source.rows[0].single().copy(colspan = 1,
            style = CellStyle(padding = edges(0f), width = StyleWidth(StyleWidthUnit.Percent, 50f)))
        val second = source.rows[1].single().copy(colspan = 1)
        val two = source.copy(rows = listOf(listOf(first, second)))
        assertTrue(tableUsesContentWidths(two))
        val grid = tableGrid(two)
        val preferences = tableCellWidthPreferences(grid, null, 0, 1f, 20f)
        val widths = checkNotNull(inlineTableColumnWidths(grid, intArrayOf(20, 35), intArrayOf(80, 200),
            0, 0, 1000, authoredWidth = 200, cellPreferences = preferences))
        assertEquals(listOf(100, 100), widths)
        val pixels = checkNotNull(tablePixelLayout(grid, 1, 20, intArrayOf(30, 40), columnWidths = widths))
        assertEquals(200, pixels.width)
        assertEquals(100, pixels.cellLeft(1))
        assertEquals(100, pixels.physicalCellLeft(0, 1, true))
        val fixed = two.copy(rows = listOf(listOf(first.copy(style = CellStyle(padding = edges(0f),
            width = StyleWidth(StyleWidthUnit.Px, 65f))), second)))
        assertEquals(listOf(65, 135), inlineTableColumnWidths(tableGrid(fixed), intArrayOf(20, 35),
            intArrayOf(65, 200), 0, 0, 1000, authoredWidth = 200,
            cellPreferences = tableCellWidthPreferences(tableGrid(fixed), null, 0, 1f, 20f)))
        assertEquals(50f, first.style!!.width!!.value, 0f)
    }

    @Test fun enrolledNonfloatingFigureCellRetainsItsOriginalNativeContext() {
        fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
        val zero = StyleEdges(px(0f), px(0f), px(0f), px(0f))
        val borders = FigureBorderEdges(FigureBorderEdge.None, FigureBorderEdge.None,
            FigureBorderEdge.None, FigureBorderEdge.None)
        fun figure(file: String) = Figure(FigureContent.Image(Span("external_link", "",
            "https://example.invalid/$file", image = InlineImage(file, widthPx = 190, heightPx = 248)),
            FigureSizingPolicy.RequestedFit), FigureFormat.Thumbnail, FigurePlacement.None, FigureClear.None,
            zero, zero, zero, 1f, px(24f), FigureColor.Transparent, FigureBorder.None,
            FigureColor.Transparent, FigureBorder.None, FigureColor.NativeTheme, FigureColor.Transparent,
            caption = listOf(Span("link", "Retained caption", "Target")),
            tableCaptionLayout = TableCaptionLayout(TableCollapse.Collapse, ContainerStyle(), borders, borders,
                FigureMediaLayout(FigureMediaStrut(1f, direction = BidiResolvedDirection.Ltr),
                    InlineBoxVerticalAlign.Middle, positioning = ContainerPositioning.RelativeAuto)))
        val sources = listOf("First.png", "Second.jpg").map { file ->
            Block("paragraph", 0, emptyList(), figure = figure(file))
        }
        val table = Table(emptyList(), sources.map { block ->
            listOf(Cell(emptyList(), false, 10, 1, blocks = listOf(block)))
        }, style = TableStyle(floatSide = TableFloatSide.Right, clear = FigureClear.Right))
        assertTrue(nativeDelegatedFigureTable(table))
        sources.forEachIndexed { index, source ->
            val blocks = checkNotNull(table.rows[index].single().blocks)
            assertSame(source, blocks.single())
            assertFalse(source.needsNativeBlockContext())
            assertFalse(blocks.needsNativeBlockSequence(null))
            assertTrue(blocks.needsNativeBlockSequence(source))
            // Equal text/model values do not transfer the physical source owner.
            assertEquals(source, source.copy())
            assertFalse(blocks.needsNativeBlockSequence(source.copy()))
            assertFalse(blocks.needsNativeBlockSequence(sources[1 - index]))
            assertFalse((blocks + source.copy()).needsNativeBlockSequence(source))
            assertEquals("Retained caption", source.figure!!.caption.single().text)
            assertEquals("Target", source.figure!!.caption.single().target)
        }
        assertFalse(emptyList<Block>().needsNativeBlockSequence(sources.first()))
        val floating = sources.first().copy(figure = sources.first().figure!!.copy(placement = FigurePlacement.FloatLeft))
        assertTrue(listOf(floating).needsNativeBlockSequence(null))
        assertTrue(listOf(floating).needsNativeBlockSequence(sources.last()))
    }

    @Test fun tableOnlySectionOwnsFollowingVisibleHeadingListsAndStableRowKeys() {
        val table = Table(emptyList(), listOf(listOf(Cell(listOf(Span("text", "2")), false, 1, 1))),
            style = TableStyle(floatSide = TableFloatSide.Right))
        val sections = listOf(Section(2, "Poloniera", listOf(Block("table", 0, emptyList(), table = table))),
            Section(3, "Ahoskera", listOf(Block("list_item", 1, listOf(Span("text", "one")), listPath = "*"),
                Block("list_item", 1, listOf(Span("text", "two")), listPath = "*"))),
            Section(3, "Adjektiboa", listOf(Block("indent", 1, listOf(Span("text", "word"))))))
        val rows = readingRows(sections)
        val run = floatBodyRuns(rows).single()
        assertEquals(1, run.first); assertEquals(rows.lastIndex, run.last)
        assertEquals(listOf("heading-1", "heading-2"), rows.slice(run).filter { it.heading != null }.map { it.key })
        val folded = visibleReadingRows(rows, setOf("heading-1"))
        val foldedRun = floatBodyRuns(folded).single()
        assertTrue(folded.slice(foldedRun).any { it.key == "heading-1" })
        assertFalse(folded.slice(foldedRun).any { it.key.startsWith("block-1-") })
        assertEquals(rows.map { it.key }.filterNot { it.startsWith("block-1-") }, folded.map { it.key })
    }
}
