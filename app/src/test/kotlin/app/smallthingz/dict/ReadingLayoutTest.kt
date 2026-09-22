package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class ReadingLayoutTest {
    @Test fun denseListsAreLazyWithoutLosingTextOrLinkSemantics() {
        val spans = (0 until 330).flatMap { index -> listOf(Span("text", "• "), Span("link", "word $index", target = "word $index", italic = true), Span("line_break", "\n")) }
        val rows = readingRows(listOf(Section(3, "Derived terms", listOf(Block("paragraph", 0, spans)))))
        val blocks = rows.mapNotNull { it.block }
        assertEquals(330, blocks.size)
        assertEquals(rows.size, rows.map { it.key }.toSet().size)
        assertTrue(blocks.all { it.spans.size == 2 })
        assertEquals(spans.filter { it.kind != "line_break" }, blocks.flatMap { it.spans })
    }
    @Test fun preformattedAndShortStyledParagraphsKeepExplicitBreaks() {
        val spans = listOf(Span("text", "first"), Span("line_break", "\n"), Span("text", "second", bold = true))
        val pre = Block("preformatted", 0, List(40) { spans }.flatten())
        val paragraph = Block("paragraph", 0, spans)
        val rows = readingRows(listOf(Section(3, "Noun", listOf(pre, paragraph))))
        assertSame(pre, rows[1].block)
        assertSame(paragraph, rows[2].block)
    }

    @org.junit.Test fun foldingEtymologyKeepsNestedDefinitionsVisible() {
        val sections=listOf(Section(3,"Etymology 1",listOf(Block("paragraph",0,listOf(Span("text","Origin"))))),Section(4,"Noun",listOf(Block("definition",1,listOf(Span("text","Meaning"))))))
        val visible=visibleReadingRows(readingRows(sections),setOf("heading-0"))
        org.junit.Assert.assertFalse(visible.any{it.block?.spans?.any{span->span.text=="Origin"}==true})
        org.junit.Assert.assertTrue(visible.any{it.block?.spans?.any{span->span.text=="Meaning"}==true})
    }

    @Test fun defaultsShowDefinitionsAndFoldSupportingSections() {
        val meaning = Block("definition", 1, listOf(Span("text", "A meaning")))
        val note = Block("quotation", 1, listOf(Span("text", "A quotation")))
        val rows = readingRows(listOf(
            Section(3, "Alternative forms", listOf(note)),
            Section(3, "Etymology 1", listOf(note)),
            Section(4, "Adjective", listOf(note, meaning, note)),
            Section(5, "Derived terms", listOf(note))
        ))
        val folded = rows.filter { initiallyFolded(it, AppSettings()) }.map { it.key }.toSet() + "heading-2-details"
        val visible = visibleReadingRows(rows, folded)
        assertEquals(listOf(meaning), visible.mapNotNull { it.block })
        assertEquals(3, visibleReadingRows(rows, folded - "heading-2-details").count { it.block != null })
        assertFalse(initiallyFolded(rows.first(), AppSettings(collapseOtherSections = false)))
    }

    @Test fun semanticSpacingDropsEmptyRowsAndRepeatedBreaksButKeepsLiteralSpacing() {
        val br = Span("line_break", "\n")
        val spans = listOf(br, br, Span("text", "one"), br, br, Span("text", " "), br, Span("text", "two"), br, br)
        val rows = readingRows(listOf(Section(3, "Noun", listOf(
            Block("definition", 1, spans), Block("paragraph", 0, listOf(br, br)), Block("preformatted", 0, spans)
        ))))
        assertEquals(3, rows.size)
        assertEquals(listOf(Span("text", "one"), br, Span("text", "two")), rows[1].block!!.spans)
        assertEquals(spans, rows[2].block!!.spans)
    }
}
