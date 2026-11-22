package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Source controls only; no allocator or platform focus equivalence is asserted here. */
class TablePairedViewportTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun edges() = StyleEdges(px(.25f), px(6.5f), px(5.25f), px(4.5f))
    private fun narrow(focus: TableScrollFocusPaint = TableScrollFocusPaint(TableScrollFocusMode.UaAuto)) =
        TableBlockViewport(639, TableStyle(margins = edges(), padding = edges(), clear = FigureClear.Right,
            border = StyleBorder.None, background = "#abcdef"), ContainerBoxSizing.BorderBox,
            StyleWidth(StyleWidthUnit.Percent, 100f), TableStyle(collapse = TableCollapse.Collapse),
            TableContainingDirection.Ltr, "de", focus)
    private fun source() = Table(emptyList(), listOf(
        listOf(Cell(listOf(Span("link", "A", "Target-A", targetFragment = "part", trail = "s")), false, 1, 2),
            Cell(listOf(Span("link", "B", "Target-B")), true, 7, 1)),
        listOf(Cell(listOf(Span("text", "C")), false, 2, 1))),
        style = TableStyle(margins = edges(), floatSide = TableFloatSide.Right, collapse = TableCollapse.Collapse),
        blockViewport = narrow(), floatViewport = TableFloatViewport(639,
            TableContainingDirection.Rtl, TableContainingDirection.Ltr, "de"))
    private fun rejects(body: () -> Unit) {
        try { body(); fail("Expected model rejection") } catch (_: IllegalArgumentException) { }
    }

    @Test fun pairedStateUsesExactThresholdAndRetainsActualCellsAndActionIdentity() {
        val value = source()
        val cells = value.rows.flatten()
        for (width in listOf(638.75, 639.0, 639.25, 1000.0, 0.0, 639.0)) {
            val narrow = width <= 639.0
            assertSame(if (narrow) value.blockViewport else null, value.blockViewportAt(width))
            assertSame(if (narrow) value.blockViewport!!.boxStyle else value.style, value.effectiveFloatStyle(width))
            assertSame(cells[0], value.rows[0][0])
            assertEquals(listOf(2, 1), value.rows.map { it.size })
            assertEquals(7, value.rows[0][1].colspan)
            assertEquals(2, value.rows[0][0].rowspan)
            assertEquals(cells, tableGrid(value).cells.map { it.cell })
            assertEquals(3, tableGrid(value).cells.size)
            assertEquals("part", value.rows[0][0].spans.single().targetFragment)
            assertEquals("s", value.rows[0][0].spans.single().trail)
            assertEquals(TableContainingDirection.Rtl, value.floatViewport!!.containingDirection)
        }
        assertSame(value.blockViewport, value.blockViewportAt(638.75f))
        assertSame(value.blockViewport, value.blockViewportAt(639f))
        assertNull(value.blockViewportAt(639.25f))
        for (width in listOf(-1.0, Double.NaN, Double.POSITIVE_INFINITY)) {
            rejects { value.blockViewportAt(width) }; rejects { value.effectiveFloatStyle(width) }
        }
    }

    @Test fun focusModeKeepsNativeColorRequestSeparateFromLayout() {
        val original = source()
        for (color in listOf(null, FigureColor.NativeTheme, FigureColor.Transparent, FigureColor.Rgb("#3366cc"))) {
            val focus = TableScrollFocusPaint(TableScrollFocusMode.UaAuto, color)
            val changed = original.copy(blockViewport = original.blockViewport!!.copy(focusPaint = focus))
            assertEquals(original.blockViewport!!.boxStyle, changed.blockViewport!!.boxStyle)
            assertEquals(original.rows, changed.rows)
            assertEquals(focus, changed.blockViewport!!.focusPaint)
        }
        val none = TableScrollFocusPaint(TableScrollFocusMode.AuthoredNone)
        assertEquals(none, original.copy(blockViewport = narrow(none)).blockViewport!!.focusPaint)
        for (color in listOf(FigureColor.NativeTheme, FigureColor.Transparent, FigureColor.Rgb("#3366cc")))
            rejects { TableScrollFocusPaint(TableScrollFocusMode.AuthoredNone, color) }
        rejects { FigureColor.Rgb("#3366CC") }
    }

    @Test fun pairedHeadersRejectMismatchesAndConflictingOwners() {
        val good = source(); val block = good.blockViewport!!; val floating = good.floatViewport!!
        val invalid = listOf<() -> Unit>(
            { good.copy(blockViewport = block.copy(maxViewportWidthPx = 638)) },
            { good.copy(floatViewport = floating.copy(maxViewportWidthPx = 0)) },
            { good.copy(blockViewport = block.copy(gridDirection = TableContainingDirection.Rtl)) },
            { good.copy(blockViewport = block.copy(language = "fr")) },
            { good.copy(floatViewport = floating.copy(narrowClear = FigureClear.None)) },
            { good.copy(geometry = TableGeometry(border = 0)) },
            { good.copy(style = good.style!!.copy(floatSide = TableFloatSide.Left)) },
            { good.copy(style = good.style!!.copy(width = StyleWidth(StyleWidthUnit.Percent, 50f))) },
            { good.copy(style = good.style!!.copy(padding = edges())) },
            { good.copy(style = good.style!!.copy(display = TableDisplay.Table)) },
            { good.copy(caption = listOf(Span("text", "caption"))) },
            { good.copy(captionBlocks = emptyList()) },
            { good.copy(rows = listOf(emptyList())) },
            { good.copy(floatViewport = null) },
            { good.copy(blockViewport = standalone()) }
        )
        invalid.forEach(::rejects)
    }

    @Test fun fitContentAndFixedMarginsRemainExclusiveToThePairedPolicy() {
        val block = narrow()
        val invalid = listOf<() -> Unit>(
            { block.copy(boxStyle = block.boxStyle.copy(width = StyleWidth(StyleWidthUnit.Px, 200f))) },
            { block.copy(boxStyle = block.boxStyle.copy(margins = null)) },
            { block.copy(boxStyle = block.boxStyle.copy(floatSide = TableFloatSide.Right)) },
            { block.copy(boxStyle = block.boxStyle.copy(display = TableDisplay.Table)) },
            { block.copy(boxStyle = block.boxStyle.copy(collapse = TableCollapse.Collapse)) },
            { block.copy(boxStyle = block.boxStyle.copy(lineHeight = ComputedLineHeight(1f, FontScaleBasis.NormalBody))) },
            { block.copy(gridStyle = block.gridStyle.copy(background = "#ffffff")) },
            { block.copy(gridStyle = block.gridStyle.copy(padding = edges())) },
            { block.copy(gridStyle = block.gridStyle.copy(collapse = TableCollapse.Separate)) },
            { block.copy(maxWidth = StyleWidth(StyleWidthUnit.Percent, Float.NaN)) },
            { block.copy(focusPaint = null) },
            { block.copy(language = "") }
        )
        invalid.forEach(::rejects)
        assertEquals(ContainerBoxSizing.ContentBox, block.copy(boxSizing = ContainerBoxSizing.ContentBox).boxSizing)
        assertEquals(FigureClear.None, block.copy(boxStyle = block.boxStyle.copy(clear = FigureClear.None)).boxStyle.clear)
        // Raw shared language strings remain model data; native-language admission is separate.
        val raw = source().copy(blockViewport = block.copy(language = "ru--RU"),
            floatViewport = source().floatViewport!!.copy(language = "ru--RU"))
        assertEquals("ru--RU", raw.blockViewport!!.language)
    }

    private fun standalone(): TableBlockViewport {
        val zero = ContainerMargin.Length(px(0f))
        val automatic = ContainerMargins(zero, ContainerMargin.Auto, zero, ContainerMargin.Auto)
        return TableBlockViewport(639, TableStyle(width = StyleWidth(StyleWidthUnit.Percent, 70f),
            marginValues = automatic, containingDirection = TableContainingDirection.Ltr),
            ContainerBoxSizing.ContentBox, StyleWidth(StyleWidthUnit.Percent, 100f),
            TableStyle(collapse = TableCollapse.Collapse), TableContainingDirection.Ltr, "de")
    }

    @Test fun standaloneAndAbsentPoliciesRetainTheirExistingMeaning() {
        val block = standalone()
        val table = Table(emptyList(), emptyList(), blockViewport = block)
        assertNull(block.focusPaint); assertSame(block, table.blockViewportAt(639.0))
        rejects { block.copy(focusPaint = TableScrollFocusPaint(TableScrollFocusMode.UaAuto)) }
        val floated = source().copy(blockViewport = null,
            floatViewport = source().floatViewport!!.copy(narrowClear = FigureClear.Left))
        assertEquals(floated.style!!.copy(floatSide = null, clear = FigureClear.Left), floated.effectiveFloatStyle(639.0))
        assertSame(floated.style, floated.effectiveFloatStyle(639.25))
        assertNull(floated.blockViewportAt(639.0))
        val old = Table(emptyList(), emptyList())
        assertNull(old.blockViewport); assertNull(old.floatViewport); assertNull(old.effectiveFloatStyle(Double.NaN))
    }
}
