package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class FloatFormattingContextTest {
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
