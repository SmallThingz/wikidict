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
    @Test fun numberedListItemsDisplayCompiledLabelsWithoutBecomingSenses() {
        fun item(number: String, path: String = "#", depth: Int = 1) =
            Block("list_item", depth, listOf(Span("text", "An instruction")), listPath = path, number = number)
        for (number in listOf("3", "8", "9", "-2", "AA", "iii", "xxvi")) assertEquals("$number. ", blockPrefix(item(number)))
        assertEquals("• ", blockPrefix(item("", "#*", 2)))
        assertEquals("3.1. ", blockPrefix(item("3.1", "#*#", 3)))
        assertEquals("↳ ", blockPrefix(Block("list_detail", 1, emptyList(), listPath = "#:")))
        val meaning = Block("definition", 1, listOf(Span("text", "Actual dictionary meaning")), number = "1")
        assertEquals("01", blockPrefix(meaning))
        val sections = listOf(Section(3, "Instructions", listOf(item("3"))), Section(3, "Meaning", listOf(meaning)))
        val rows = readingRows(sections)
        assertFalse(rows.first { it.block?.kind == "list_item" }.meaningSection)
        assertTrue(rows.first { it.block?.kind == "definition" }.meaningSection)
        val entry = Entry("word", emptyList(), "language", "Language", "und", sections, emptyList())
        assertEquals("Actual dictionary meaning", entry.clue())
    }

    @Test fun sameEntryFragmentsMatchCompiledHeadingsWithoutChangingWordLinks() {
        val entry = Entry("cat", emptyList(), "language", "English", "en", listOf(
            Section(3, "Noun", emptyList()),
            Section(3, "Usage notes", listOf(Block("paragraph", 0, listOf(Span("text", "Usage body"))))),
            Section(4, "日本語", emptyList())
        ), emptyList())
        assertEquals("heading-1", sectionScrollKey(entry, "#Usage_notes"))
        assertEquals("heading-1", sectionScrollKey(entry, "#Usage notes"))
        assertEquals("heading-2", sectionScrollKey(entry, "#日本語"))
        listOf("cat", "cat#Usage_notes", "#", "#Missing", "#usage_notes").forEach {
            assertNull(sectionScrollKey(entry, it))
        }
    }

    @Test fun compiledReferenceTargetsUseGlobalIdentityAndGroupedDisplayLabels() {
        val references = listOf(
            Reference(1, 1, "notes", listOf(Span("text", "Grouped note"))),
            Reference(2, 1, "", listOf(Span("text", "Default note"))),
            Reference(3, 2, "notes", listOf(Span("text", "Second grouped note")))
        )
        val entry = Entry("reference fixture", emptyList(), "language", "English", "en", listOf(
            Section(3, "Usage notes", listOf(Block("paragraph", 0, listOf(Span("text", "Body")))))
        ), references, listOf(Span("text", "Preamble")), emptyList())
        assertEquals(listOf("[notes 1]", "[1]", "[notes 2]"), references.map(::referenceLabel))
        val folded = setOf("heading-0", "references")
        // Title, preamble, folded section heading, references heading, then reference rows.
        assertEquals(4, referenceScrollIndex(entry, "#reference-1", folded))
        assertEquals(5, referenceScrollIndex(entry, "#reference-2", folded))
        assertEquals(6, referenceScrollIndex(entry, "#reference-3", folded))
        assertEquals(7, referenceScrollIndex(entry, "#reference-3", emptySet()))
        assertEquals(5, referenceScrollIndex(entry.copy(preamble = emptyList()), "#reference-3", folded))
        listOf("word", "word#reference-1", "#reference-01", "#reference-4", "#cite_note-1").forEach {
            assertNull(referenceScrollIndex(entry, it, folded))
        }
    }

    @Test fun spanLanguageTagsPreserveExplicitScriptRegionAndExtensions() {
        for ((raw, expected) in listOf(
            "ja" to "ja", "EN-us" to "en-US", "zh-Hant-TW" to "zh-Hant-TW",
            "sr-Latn-RS" to "sr-Latn-RS", "de-DE-x-goethe" to "de-DE-x-goethe",
            "en-US-u-nu-latn" to "en-US-u-nu-latn",
            "und" to "und", "und-Latn" to "und-Latn", "x-private" to "x-private"
        )) assertEquals(raw, expected, spanLanguageTag(raw))
    }

    @Test fun absentOrMalformedLanguageTagsAreIgnored() {
        for (raw in listOf("", " ", "en_US", "en--US", "en,fr", "1en", "en-US-", " en", "en ")) {
            assertNull(raw, spanLanguageTag(raw))
        }
    }

}
