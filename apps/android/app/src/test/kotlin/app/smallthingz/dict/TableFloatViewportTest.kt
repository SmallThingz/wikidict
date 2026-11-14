package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Closed Mai placement policy controls. Source only; not compiled or executed. */
class TableFloatViewportTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private val margins = StyleEdges(StyleLength(StyleLengthUnit.Em, .25f), px(6f),
        StyleLength(StyleLengthUnit.Em, .5f), px(4f))
    private val base = TableStyle(background = "#abcdef", border = StyleBorder.None,
        collapse = TableCollapse.Collapse, margins = margins, floatSide = TableFloatSide.Right,
        clear = FigureClear.Both)
    private val policy = TableFloatViewport(639, TableContainingDirection.Ltr,
        TableContainingDirection.Rtl, "de")
    private val cell = Cell(listOf(Span("link", "Mai", "Mai#Deutsch", bold = true)), false, 1, 1)
    private fun table() = Table(emptyList(), listOf(listOf(cell)), style = base, floatViewport = policy)

    @Test fun fractionalRootBoundaryChangesOnlyPhysicalSideAndKeepsSourceOwners() {
        val table = table()
        for (containing in TableContainingDirection.entries) for (grid in TableContainingDirection.entries) {
            val original = table.copy(floatViewport = policy.copy(containingDirection = containing, gridDirection = grid))
            for (width in listOf(0.0, 638.75, 639.0)) {
                val effective = original.effectiveFloatStyle(width)!!
                assertNull(effective.floatSide)
                assertEquals(base.copy(floatSide = null), effective)
                assertEquals(containing, original.floatViewport!!.containingDirection)
                assertEquals(grid, original.floatViewport!!.gridDirection)
                assertEquals("de", original.floatViewport!!.language)
            }
            for (width in listOf(639.0000001, 639.5, 640.0, 800.0))
                assertSame(base, original.effectiveFloatStyle(width))
            assertSame(base, original.style)
            assertEquals(TableFloatSide.Right, original.style!!.floatSide)
            assertSame(table.rows, original.rows)
            assertSame(cell, original.rows.single().single())
            assertEquals("Mai#Deutsch", original.rows.single().single().spans.single().target)
        }
        val ordinary = table.copy(floatViewport = null)
        assertSame(base, ordinary.effectiveFloatStyle(639.0))
        assertNull(Table(emptyList(), emptyList()).effectiveFloatStyle(639.0))
    }

    @Test fun thresholdIsPositiveUnsignedAndTheViewportRemainsFractionalAndFinite() {
        for (threshold in listOf(1L, 639L, 0xffff_ffffL)) {
            val table = table().copy(floatViewport = policy.copy(maxViewportWidthPx = threshold))
            assertNull(table.effectiveFloatStyle(threshold.toDouble())!!.floatSide)
            assertSame(base, table.effectiveFloatStyle(threshold.toDouble() + .5))
        }
        for (threshold in listOf(-1L, 0L, 0x1_0000_0000L))
            assertThrows(IllegalArgumentException::class.java) { policy.copy(maxViewportWidthPx = threshold) }
        for (width in listOf(-1.0, Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            assertThrows(IllegalArgumentException::class.java) { table().effectiveFloatStyle(width) }
            assertSame(base, table().copy(floatViewport = null).effectiveFloatStyle(width))
            assertNull(Table(emptyList(), emptyList()).effectiveFloatStyle(width))
        }
    }

    @Test fun closureRejectsUnimplementedBoxesAndCaptionsWithoutLosingEmptyCells() {
        val original = table()
        for (style in listOf<TableStyle?>(null, base.copy(floatSide = null), base.copy(floatSide = TableFloatSide.Left),
            base.copy(margins = null), base.copy(width = StyleWidth(StyleWidthUnit.Percent, 70f)),
            base.copy(padding = margins), base.copy(display = TableDisplay.Table),
            base.copy(verticalAlign = InlineBoxVerticalAlign.Middle), base.copy(lineHeight = ComputedLineHeight(1f)),
            base.copy(margins = null, marginValues = ContainerMargins(ContainerMargin.Length(px(0f)),
                ContainerMargin.Auto, ContainerMargin.Length(px(0f)), ContainerMargin.Auto),
                containingDirection = TableContainingDirection.Ltr))) {
            assertThrows(IllegalArgumentException::class.java) { original.copy(style = style) }
        }
        for (geometry in listOf(TableGeometry(), TableGeometry(border = 0), TableGeometry(cellPadding = 0)))
            assertThrows(IllegalArgumentException::class.java) { original.copy(geometry = geometry) }
        assertThrows(IllegalArgumentException::class.java) { original.copy(caption = listOf(Span("text", "caption"))) }
        for (caption in listOf(emptyList(), listOf(Block("paragraph", 0, listOf(Span("text", "caption"))))))
            assertThrows(IllegalArgumentException::class.java) { original.copy(captionBlocks = caption) }
        for (rows in listOf(emptyList(), listOf(emptyList<Cell>())))
            assertThrows(IllegalArgumentException::class.java) { original.copy(rows = rows) }
        val empty = Cell(emptyList(), false, 1, 1)
        assertSame(empty, original.copy(rows = listOf(listOf(empty))).rows.single().single())
        val auto = ContainerMargins(ContainerMargin.Length(px(0f)), ContainerMargin.Auto,
            ContainerMargin.Length(px(0f)), ContainerMargin.Auto)
        val block = TableBlockViewport(639,
            TableStyle(width = StyleWidth(StyleWidthUnit.Percent, 70f), marginValues = auto,
                containingDirection = TableContainingDirection.Ltr), ContainerBoxSizing.ContentBox,
            StyleWidth(StyleWidthUnit.Percent, 100f), TableStyle(collapse = TableCollapse.Collapse),
            TableContainingDirection.Rtl, "de")
        assertThrows(IllegalArgumentException::class.java) { original.copy(blockViewport = block) }
        // Legacy/null records retain their earlier, wider model domain.
        assertNotNull(Table(listOf(Span("text", "caption")), emptyList(), geometry = TableGeometry(), style = base))
    }

    @Test fun sourceLanguageUsesSharedUtf8DomainWithoutNativeLocaleAdmission() {
        for (source in listOf("de", "DE", "sr-Latn-RS", "de--DE", "not a locale", "\u65e5\u672c", "\uD83D\uDE00", "\u0000"))
            assertEquals(source, policy.copy(language = source).language)
        for (source in listOf("", "\uD800", "\uDC00"))
            assertThrows(IllegalArgumentException::class.java) { policy.copy(language = source) }
        val oversized = "\u0800".repeat(32 * 1024 * 1024 / 3 + 1)
        assertThrows(IllegalArgumentException::class.java) { policy.copy(language = oversized) }
    }

    @Test fun fixedWidthsAndNullableClearChangeOnlyTheSelectedNarrowPlacement() {
        for (unit in listOf(StyleWidthUnit.Px, StyleWidthUnit.Em)) for (value in listOf(0f, 25f, 127.25f)) {
            val preferred = StyleWidth(unit, value)
            for (baseClear in listOf(null) + FigureClear.entries) for (clearOverride in listOf(null) + FigureClear.entries) {
                val style = base.copy(width = preferred, clear = baseClear)
                val original = table().copy(style = style, floatViewport = policy.copy(narrowClear = clearOverride))
                for (rootWidth in listOf(0.0, 638.75, 639.0)) {
                    val effective = original.effectiveFloatStyle(rootWidth)!!
                    assertEquals(style.copy(floatSide = null, clear = clearOverride ?: baseClear), effective)
                    assertSame(preferred, effective.width)
                    assertSame(style.margins, effective.margins)
                }
                for (rootWidth in listOf(639.0000001, 639.5, 640.0))
                    assertSame(style, original.effectiveFloatStyle(rootWidth))
                assertSame(style, original.style); assertSame(cell, original.rows.single().single())
                assertEquals("Mai#Deutsch", original.rows.single().single().spans.single().target)
                assertEquals(TableContainingDirection.Ltr, original.floatViewport!!.containingDirection)
                assertEquals(TableContainingDirection.Rtl, original.floatViewport!!.gridDirection)
                assertEquals("de", original.floatViewport!!.language)
            }
        }
        val source = table().copy(style = base.copy(width = StyleWidth(StyleWidthUnit.Em, 25f), clear = FigureClear.Right),
            floatViewport = policy.copy(narrowClear = FigureClear.Both))
        assertEquals(FigureClear.Both, source.effectiveFloatStyle(639.0)!!.clear)
        assertEquals(FigureClear.Right, source.effectiveFloatStyle(639.5)!!.clear)
        assertEquals(FigureClear.Right, source.copy(floatViewport = policy).effectiveFloatStyle(639.0)!!.clear)
        assertEquals(FigureClear.None, source.copy(floatViewport = policy.copy(narrowClear = FigureClear.None))
            .effectiveFloatStyle(639.0)!!.clear)
    }

    @Test fun preferredWidthAdmissionPreservesTheExistingClosedFloatOwner() {
        for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY))
            assertThrows(IllegalArgumentException::class.java) {
                table().copy(style = base.copy(width = StyleWidth(StyleWidthUnit.Em, value)))
            }
        for (percent in listOf(0f, 25f, 100f)) assertThrows(IllegalArgumentException::class.java) {
            table().copy(style = base.copy(width = StyleWidth(StyleWidthUnit.Percent, percent)))
        }
        val fixed = table().copy(style = base.copy(width = StyleWidth(StyleWidthUnit.Em, 25f)),
            floatViewport = policy.copy(narrowClear = FigureClear.Both))
        for (style in listOf(fixed.style!!.copy(floatSide = TableFloatSide.Left), fixed.style!!.copy(margins = null),
            fixed.style!!.copy(padding = margins), fixed.style!!.copy(display = TableDisplay.Table)))
            assertThrows(IllegalArgumentException::class.java) { fixed.copy(style = style) }
        assertThrows(IllegalArgumentException::class.java) { fixed.copy(captionBlocks = emptyList()) }
        assertThrows(IllegalArgumentException::class.java) { fixed.copy(geometry = TableGeometry()) }
        assertEquals(fixed, fixed.copy()); assertSame(fixed.rows, fixed.copy().rows)
    }
}
