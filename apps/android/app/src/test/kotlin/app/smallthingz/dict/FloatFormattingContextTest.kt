package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class FloatFormattingContextTest {
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
