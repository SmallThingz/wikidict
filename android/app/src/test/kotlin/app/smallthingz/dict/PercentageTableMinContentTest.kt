package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Synthetic geometry control, not a genuine payload/font/render qualification. */
class PercentageTableMinContentTest {
    @Test fun percentageUsesRealCellFloorsAndStillFitsWhenContainingWidthAllows() {
        fun cell(columns:Int=1)=Cell(listOf(Span("text","word")),false,columns,1)
        val table=Table(emptyList(),listOf(listOf(cell(2),cell()),listOf(cell(),cell(),cell())),
            style=TableStyle(width=StyleWidth(StyleWidthUnit.Percent,90f)))
        val sourceRows=table.rows;val grid=tableGrid(table)
        assertTrue("Percentage safe cells must reach the genuine intrinsic branch",tableUsesContentWidths(table))
        assertFalse(tableUsesContentWidths(table.copy(style=null)))
        assertFalse(tableUsesContentWidths(table.copy(rows=emptyList())))
        assertFalse(tableUsesContentWidths(table.copy(style=TableStyle(width=StyleWidth(StyleWidthUnit.Px,252f)))))
        assertFalse(tableUsesContentWidths(table.copy(style=null,geometry=TableGeometry(width=TableWidth(TableWidthUnit.Percent,90)))))
        assertTrue(tableUsesContentWidths(table.copy(style=null),inherited=true))
        val rich=table.copy(rows=listOf(listOf(Cell(emptyList(),false,1,1,
            blocks=listOf(Block("paragraph",0,listOf(Span("text","body"))))))))
        assertFalse("No new rich-block intrinsic admission",tableUsesContentWidths(rich))
        val natural=checkNotNull(tableRenderMetrics(table,136,10,40,1f,containerFontPixels=20f))
        // Cell-border-box minima already include insets, as actual cell intrinsics do.
        // First row has a two-column span; second row contributes individual floors.
        val minimum=intArrayOf(200,140,80,100,120)
        val maximum=intArrayOf(280,180,120,140,180)
        fun measured(containing:Int):TableRenderMetrics {
            val requested=checkNotNull(tableMetricsInWidth(table,natural,grid.columns,containing)).width
            return checkNotNull(inlineTableMetrics(natural,grid,minimum,maximum,containing,authoredWidth=requested))
        }
        val narrow=measured(280)
        assertEquals(listOf(90,110,140),narrow.columnWidths)
        assertEquals(340,narrow.width);assertTrue(narrow.width>280)
        assertEquals(200,narrow.cellWidth(0,2));assertEquals(140,narrow.cellWidth(2,1))
        val wide=measured(1000)
        assertEquals(900,wide.width);assertTrue(wide.width<=1000)
        for(index in minimum.indices){val placed=grid.cells[index]
            assertTrue(wide.cellWidth(placed.column,placed.colspan)>=minimum[index])}
        assertSame(sourceRows,table.rows);assertEquals(2,table.rows[0][0].colspan)
        assertEquals(StyleWidth(StyleWidthUnit.Percent,90f),table.style!!.width)
    }
}
