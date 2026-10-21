package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class InlineWhitespaceTest {
    private fun text(spans: List<Span>) = spans.joinToString("") { if (it.kind == "line_break") "\n" + it.trail else it.text + it.trail }

    @Test fun savedGlossarySpacesCollapseOnlyInDisplayAndLeaveRawSpansUntouched() {
        val raw = listOf(Span("text", "stack የስራ-ክምር ste  street መንገድ"),
            Span("text", " save ይኑር  ጠብቕ"))
        val block = Block("paragraph", 0, raw)
        assertEquals("stack የስራ-ክምር ste street መንገድ save ይኑር ጠብቕ", text(ordinaryInlineDisplaySpans(block)))
        assertSame(raw, block.spans)
        assertEquals("stack የስራ-ክምር ste  street መንገድ", raw[0].text)
        assertEquals(" save ይኑር  ጠብቕ", raw[1].text)
    }

    @Test fun crossSpanCollapseKeepsVisibleStyleAndActionOwnership() {
        val first = Span("text", "left  ", italic = true, trail = "\t")
        val link = Span("link", "\t target", target = "B#English", bold = true, language = "en", direction = "ltr")
        val whitespaceLink = Span("link", " \t", target = "must-not-be-an-invisible-action")
        val tail = Span("text", " \t right")
        val result = ordinaryInlineDisplaySpans(Block("definition", 1, listOf(first, link, whitespaceLink, tail)))
        assertEquals("left target right", text(result))
        assertEquals(first.copy(text = "left ", trail = ""), result[0])
        assertEquals(link.copy(text = "target"), result[1])
        assertEquals(whitespaceLink.copy(text = " "), result[2])
        assertEquals(tail.copy(text = "right"), result[3])
        assertEquals("\t target", link.text)
    }

    @Test fun literalBlocksCodeNonbreakingSpacesAndExplicitBreaksKeepTheirContract() {
        val literal = listOf(Span("text", "a  \t b"))
        for (kind in listOf("preformatted", "term", "example")) {
            assertSame(literal, ordinaryInlineDisplaySpans(Block(kind, 0, literal)))
        }
        val table = Block("paragraph", 0, literal, table = Table(emptyList(), listOf(listOf(Cell(literal, false, 1, 1)))))
        assertSame(literal, ordinaryInlineDisplaySpans(table))
        val poem = listOf(Span("text", "poem  \t kept", classes = "wikidict-poem"), Span("text", "  also kept"))
        assertSame(poem, ordinaryInlineDisplaySpans(Block("paragraph", 0, poem)))
        val code = Span("text", "code \t  kept", code = true)
        val hardBreak = Span("line_break", "", trail = "  ")
        val spans = listOf(Span("text", "a  \u00a0  b  "), hardBreak, Span("text", " \t c  "), code, Span("text", "  d"))
        val result = ordinaryInlineDisplaySpans(Block("paragraph", 0, spans))
        assertEquals("a \u00a0 b \n   c code \t  kept d", text(result))
        assertSame(hardBreak, result[1]); assertSame(code, result[3])
    }
}
