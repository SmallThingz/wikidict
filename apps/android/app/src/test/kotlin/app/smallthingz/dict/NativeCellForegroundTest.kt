package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativeCellForegroundTest {
    @Test fun symbolicBodyInkKeepsIndependentLinkBackgroundAndAuthoredGroupPrecedence() {
        val green = 0xff00c040.toInt()
        val purple = 0xffa000c0.toInt()
        val white = 0xffffffff.toInt()
        val black = 0xff000000.toInt()
        val red = 0xffff0000.toInt()
        fun plain(context: NativeCellForegroundContext?, own: String? = null, explicit: Int? = null) =
            nativeCellPlainForeground(context, explicit, context?.authored, own, own ?: "#000000", false)
        fun link(context: NativeCellForegroundContext?, own: String? = null, explicit: Int? = null) =
            nativeCellLinkForeground(context, explicit, context?.authored, own, own ?: "#000000", false)
        for (enclosing in listOf(green, purple, green)) {
            val marked = checkNotNull(nativeCellForegroundContext(CellForeground.Inherit, enclosing, "#000000", null))
            assertEquals(enclosing, plain(marked))
            assertEquals(white, link(marked))
            assertEquals(black, plain(marked, "#ffffff"))
            assertEquals(black, link(marked, "#ffffff"))
            assertEquals(red, plain(marked, "#ffffff", red))
            assertEquals(red, link(marked, "#ffffff", red))
            assertEquals(enclosing, nativeCellPlainForeground(marked, null, null, null, null, true))
            assertNull(nativeCellPlainForeground(null, null, null, null, null, true))
            assertNull(nativeCellLinkForeground(marked, null, null, null, null, true))
            // Font-only / unpainted Box ancestry cannot promote cell ink into link ink.
            val unpainted = marked.inGroup(false, enclosing)
            assertEquals(enclosing, plain(unpainted)); assertEquals(white, link(unpainted))
            val authoredGroup = marked.inGroup(true, red)
            assertEquals(red, plain(authoredGroup)); assertEquals(red, link(authoredGroup))
            val backgroundGroup = marked.inGroup(true, black)
            assertEquals(black, plain(backgroundGroup)); assertEquals(black, link(backgroundGroup))
            // A real Figure-caption foreground wins without changing null policy.
            assertEquals(red, plain(marked.withAuthored(red)))
            assertNull(nativeCellForegroundContext(null, enclosing, "#000000", null))
            assertEquals(white, plain(null)); assertEquals(white, link(null))
        }
        // Deliberately equal RGB values carry different provenance. A later authored
        // white Container must resolve contrast again only for inherited cell ink.
        val inheritedWhite = checkNotNull(nativeCellForegroundContext(CellForeground.Inherit, white, "#000000", null))
        val authoredWhite = inheritedWhite.inGroup(true, white)
        assertEquals(black, inheritedWhite.atBackground("#ffffff", null).plain)
        assertEquals(white, authoredWhite.atBackground("#ffffff", null).plain)
        val innerMarked = nativeCellForegroundContext(CellForeground.Inherit, white, "#ffffff", null)
        assertEquals(white, nativeCellPlainForeground(innerMarked, null, null, null, "#ffffff", false))
        assertEquals(black, nativeCellPlainForeground(null, null, null, null, "#ffffff", false))
    }

    @Test fun foregroundOnlyCellPreservesGeometryDecorationAndOriginalNestedSource() {
        val text = listOf(Span("text", "Original cell body"))
        val originalCell = Cell(text, false, 1, 1)
        val original = Table(emptyList(), listOf(listOf(originalCell)))
        val markedCell = originalCell.copy(style = CellStyle(foreground = CellForeground.Inherit))
        val marked = original.copy(rows = listOf(listOf(markedCell)))
        fun metrics(table: Table, viewport: Int) = tableRenderMetrics(table, 136, 10, 40, 1f,
            containerFontPixels = 20f, decorationViewportWidth = viewport, decorationViewportHeight = viewport)
        fun geometry(value: TableRenderMetrics?): List<Any?>? = value?.let { listOf(it.width, it.columnWidth,
            it.cellPadding, it.minRowHeight, it.cellSpacing, it.borderWidth, it.extraColumns,
            it.columnWidths?.toList(), it.outerBorder, it.style) }
        assertFalse(nativeHasCellForeground(original)); assertTrue(nativeHasCellForeground(marked))
        assertFalse(tableHasOwnStyle(marked)); assertFalse(tableHasComputedCellStyle(marked))
        assertEquals(tableUsesContentWidths(original), tableUsesContentWidths(marked))
        for (viewport in listOf(0, 1, 80, 400))
            assertEquals(geometry(metrics(original, viewport)), geometry(metrics(marked, viewport)))
        assertSame(text, markedCell.spans)
        val nested = original.copy(rows = listOf(listOf(Cell(emptyList(), false, 1, 1, nestedTable = marked))))
        assertTrue(nativeHasCellForeground(nested))
        assertSame(marked, nested.rows.single().single().nestedTable)
        assertSame(text, nested.rows.single().single().nestedTable!!.rows.single().single().spans)
        val px = StyleLength(StyleLengthUnit.Px, 1000f)
        val oldStyle = CellStyle(padding = StyleEdges(px, px, px, px),
            border = StyleBorder.Solid(StyleLength(StyleLengthUnit.Px, 30f), "#123456"), opacity = .2f)
        val styled = original.copy(rows = listOf(listOf(originalCell.copy(style = oldStyle))))
        val mixed = styled.copy(rows = listOf(listOf(styled.rows[0][0].copy(
            style = oldStyle.copy(foreground = CellForeground.Inherit)))))
        for (viewport in listOf(1, 80, 400))
            assertEquals(geometry(metrics(styled, viewport)), geometry(metrics(mixed, viewport)))
        assertEquals(tableHasComputedCellStyle(styled), tableHasComputedCellStyle(mixed))
        assertTrue(mixed.hasNativeCellOpacity())
    }
}
