package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test
import androidx.compose.ui.unit.em

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

    @Test fun denseMediaCaptionKeepsOneRowAndAllCompiledSpans() {
        val owner = "File:Tone.ogg"
        val mediaClass = "caption wikidict-media"
        fun line(text: String) = text.mapIndexed { index, character ->
            Span("link", character.toString(), target = owner, classes = mediaClass, bold = index % 2 == 0)
        }
        val first = "First caption line " + "a".repeat(21)
        val second = "Second caption line " + "b".repeat(20)
        val caption = line(first) + Span("line_break", "\n", target = owner, classes = mediaClass) + line(second)
        assertEquals(81, caption.size)
        val block = Block("paragraph", 0, caption)
        val rows = readingRows(listOf(Section(3, "Pronunciation", listOf(block))))
        assertEquals(2, rows.size) // Heading plus the one original media container.
        assertSame(block, rows.last().block)
        assertEquals(caption, rows.last().block!!.spans)
        assertEquals("$first\n$second", caption.joinToString("") { it.text })
        // A substring class or an ordinary word target does not own inline media.
        for (unowned in listOf(
            caption.map { it.copy(classes = "wikidict-media-extra") },
            caption.map { it.copy(target = "Tone") },
        )) {
            val split = readingRows(listOf(Section(3, "Notes", listOf(block.copy(spans = unowned)))))
                .mapNotNull { it.block }
            assertEquals(2, split.size)
            assertEquals(unowned.filter { it.kind != "line_break" }, split.flatMap { it.spans })
        }
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


    @Test fun blankHeadingsKeepBodiesAndDetailsVisibleUnderDefaultsAndRetainedFolds() {
        for (title in listOf("", " \t\n")) {
            val prose = Block("paragraph", 0, listOf(Span("link", "Read prose", target = "prose")))
            val item = Block("list_item", 1, listOf(Span("text", "List content")), listPath = "*")
            val table = Block("table", 0, emptyList(), table = Table(emptyList(),
                listOf(listOf(Cell(listOf(Span("link", "Cell content", target = "cell")), false, 1, 1)))))
            val meaning = Block("definition", 1, listOf(Span("text", "Meaning")))
            val note = Block("quotation", 1, listOf(Span("text", "Supporting detail")))
            val named = Block("paragraph", 0, listOf(Span("text", "Named section body")))
            val rows = readingRows(listOf(
                Section(3, "Before", listOf(named)),
                Section(3, title, listOf(prose, item, table)),
                Section(3, title, listOf(meaning, note)),
                Section(3, "After", listOf(named)),
                Section(3, "Noun", listOf(meaning, note))
            ))
            val defaults = rows.filter { initiallyFolded(it, AppSettings()) }.map { it.key }.toSet() +
                setOf("heading-2-details", "heading-4-details")
            assertFalse(initiallyFolded(rows.single { it.key == "heading-1" }, AppSettings()))
            assertFalse(initiallyFolded(rows.single { it.key == "heading-2" }, AppSettings()))
            val expected = listOf(prose, item, table, meaning, note, meaning)
            assertEquals(expected, visibleReadingRows(rows, defaults).mapNotNull { it.block })
            // Retained fold indices must not hide bodies with no visible way to reopen them.
            val retained = defaults + setOf("heading-1", "heading-1-details", "heading-2")
            val visible = visibleReadingRows(rows, retained)
            assertEquals(expected, visible.mapNotNull { it.block })
            assertEquals(rows.filter { it.heading != null }, visible.filter { it.heading != null })
            // Ordinary named section and detail toggles still work.
            assertEquals(listOf(named) + expected,
                visibleReadingRows(rows, retained - "heading-0").mapNotNull { it.block })
            assertEquals(expected + note,
                visibleReadingRows(rows, retained - "heading-4-details").mapNotNull { it.block })
        }
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


    @Test fun markedPoemSpacingSurvivesCompactionDenseRowsAndTables() {
        val br = Span("line_break", "", classes = "wikidict-poem")
        val spaces = Span("text", " \u00a0 ", trail = "  ", classes = "wikidict-poem")
        val verse = Span("link", "Verse", target = "verse#Noun", trail = " ", classes = "wikidict-poem")
        val spans = listOf(br, br, spaces, verse, br, br, spaces, br)
        assertSame(spans, compactSpans(spans))
        val dense = List(45) { listOf(verse, br) }.flatten() + listOf(br, spaces, br)
        val table = Table(dense, listOf(listOf(Cell(dense, false, 1, 1))))
        val rows = readingRows(listOf(Section(3, "Poem", listOf(
            Block("paragraph", 0, dense), Block("table", 0, emptyList(), table = table)))))
        assertEquals(3, rows.size)
        assertEquals(dense, rows[1].block!!.spans)
        assertEquals(dense, rows[2].block!!.table!!.caption)
        assertEquals(dense, rows[2].block!!.table!!.rows.single().single().spans)
        val ordinaryBreak = Span("line_break", "")
        val boundary = listOf(Span("text", "before"), ordinaryBreak, verse, ordinaryBreak, Span("text", "after"))
        assertEquals(boundary, compactSpans(boundary))
        assertEquals("verse#Noun", rows[1].block!!.spans.first().target)
    }

    @Test fun poemParagraphsUseActualOffsetsRawNewlinesAndLineBoundaries() {
        val rtl = "wikidict-poem mw-poem-indented wikidict-poem-indent-3 wikidict-poem-dir-rtl"
        val ltr = "wikidict-poem mw-poem-indented wikidict-poem-indent-1 wikidict-poem-dir-ltr"
        val parts = listOf(
            Span("link", "alpha", target = "alpha", classes = rtl, direction = "ltr") to "\u2066alpha\u2069",
            Span("line_break", "", classes = rtl) to "\n",
            Span("line_break", "", classes = "wikidict-poem") to "\n",
            Span("text", "אב\n", classes = ltr, direction = "rtl") to "\u2067אב\n\u2069",
            Span("text", "ordinary") to "ordinary")
        val text = StringBuilder()
        val offsets = parts.map { (span, rendered) ->
            val start = text.length
            text.append(rendered)
            span to (start until text.length)
        }
        assertEquals("\u2066alpha\u2069\n\n\u2067אב\n\u2069ordinary", text.toString())
        assertEquals(listOf(
            PoemParagraph(0, 8, 3, "rtl"),
            PoemParagraph(8, 9, 0, null),
            PoemParagraph(9, 13, 1, "ltr")), poemParagraphs(text.toString(), offsets))
        val raw = Span("text", "a\nb", classes = rtl)
        assertEquals(listOf(PoemParagraph(0, 2, 3, "rtl"), PoemParagraph(2, 3, 0, "rtl")),
            poemParagraphs("a\nb", listOf(raw to (0 until 3))))
        val separatelyMarked = Span("text", "b", classes = ltr)
        assertEquals(listOf(PoemParagraph(0, 2, 3, "rtl"), PoemParagraph(2, 3, 1, "ltr")),
            poemParagraphs("a\nb", listOf(raw.copy(text = "a\n") to (0 until 2),
                separatelyMarked to (2 until 3))))
        val trailing = Span("text", "a\n\n", classes = "wikidict-poem")
        assertEquals(listOf(PoemParagraph(0, 2, 0, null), PoemParagraph(2, 3, 0, null)),
            poemParagraphs("a\n\n", listOf(trailing to (0 until 3))))
    }

    @Test fun poemMetadataRejectsMalformedDuplicateAndDisagreeingTokensIndependently() {
        fun line(first: String, second: String = first): PoemParagraph? =
            poemParagraphs("ab", listOf(Span("text", "a", classes = first) to (0 until 1),
                Span("text", "b", classes = second) to (1 until 2))).singleOrNull()
        val marker = "wikidict-poem"
        val depth = "$marker wikidict-poem-indent-3"
        assertEquals(PoemParagraph(0, 2, 3, "rtl"), line("$depth wikidict-poem-dir-rtl"))
        assertEquals(32, line("$marker wikidict-poem-indent-32")!!.indent)
        assertNull(line("wikidict-poem-indent-3 wikidict-poem-dir-rtl"))
        for (bad in listOf("0", "03", "+3", "33", "", "x", "999999999999999999999")) {
            assertEquals(PoemParagraph(0, 2, 0, "rtl"),
                line("$marker wikidict-poem-indent-$bad wikidict-poem-dir-rtl"))
        }
        for (bad in listOf("wikidict-poem-indent", "wikidict-poem-indentjunk")) {
            assertEquals(PoemParagraph(0, 2, 0, "rtl"),
                line("$depth $bad wikidict-poem-dir-rtl"))
        }
        for (bad in listOf("wikidict-poem-dir", "wikidict-poem-dirjunk")) {
            assertEquals(PoemParagraph(0, 2, 3, null),
                line("$depth wikidict-poem-dir-rtl $bad"))
        }
        assertEquals(0, line("$depth wikidict-poem-indent-3")!!.indent)
        assertEquals(0, line("$depth wikidict-poem-indent-2")!!.indent)
        assertEquals(0, line(depth, "$marker wikidict-poem-indent-2")!!.indent)
        assertEquals(0, line(depth, marker)!!.indent)
        for (suffix in listOf("rtl wikidict-poem-dir-rtl", "rtl wikidict-poem-dir-ltr", "auto", "")) {
            assertEquals(PoemParagraph(0, 2, 3, null), line("$depth wikidict-poem-dir-$suffix"))
        }
        assertEquals(PoemParagraph(0, 2, 3, null),
            line("$depth wikidict-poem-dir-rtl", "$depth wikidict-poem-dir-ltr"))
        assertEquals(PoemParagraph(0, 2, 3, null),
            line("$depth wikidict-poem-dir-rtl", depth))
        val mixed = Span("link", "Tone", target = "File:Tone.ogg",
            classes = "wikidict-poem\twikidict-media\nwikidict-poem-indent-3")
        assertTrue(mixed.hasClassToken("wikidict-media"))
        assertFalse(mixed.hasClassToken("media"))
        assertEquals(mixed.copy(classes = "wikidict-poem wikidict-poem-indent-3"),
            mixed.withoutClassToken("wikidict-media"))
    }

    @Test fun nativeEgyptianMappingPreservesExplicitPoemDirectionAndOrdinaryInference() {
        val witness = "𓂜"
        val cases = listOf(
            "Latin" to androidx.compose.ui.text.style.TextDirection.Rtl,
            "אב" to androidx.compose.ui.text.style.TextDirection.Ltr)
        for ((prefix, direction) in cases) {
            val text = prefix + witness
            val paragraph = androidx.compose.ui.text.ParagraphStyle(
                textDirection = direction,
                textIndent = androidx.compose.ui.text.style.TextIndent(
                    2.em, 2.em))
            val original = androidx.compose.ui.text.AnnotatedString(text,
                paragraphStyles = listOf(androidx.compose.ui.text.AnnotatedString.Range(paragraph, 0, text.length)))
            val run = EgyptianTextRun(prefix.length, text.length, witness, false)
            val mapped = egyptianInlineText(original, listOf(run), rtlFallback = false)
            assertEquals(prefix + "\u2066" + witness + "\u2069", mapped.text)
            assertEquals(listOf(androidx.compose.ui.text.AnnotatedString.Range(paragraph, 0, mapped.length)),
                mapped.paragraphStyles)
            val inferred = egyptianInlineText(androidx.compose.ui.text.AnnotatedString(text), listOf(run), rtlFallback = false)
            assertEquals(if (prefix == "Latin") androidx.compose.ui.text.style.TextDirection.Ltr
                else androidx.compose.ui.text.style.TextDirection.Rtl, inferred.paragraphStyles.single().item.textDirection)
        }
    }

    @Test fun composeBuilderParagraphsKeepActualTextAndUtf16Boundaries() {
        val marker = "wikidict-poem wikidict-poem-indent-2 wikidict-poem-dir-ltr"
        fun verify(parts: List<Pair<Span, String>>, expectedText: String,
                   expectedParagraphs: List<PoemParagraph>) {
            var paragraphs = emptyList<PoemParagraph>()
            var ranges = emptyList<Pair<Span, IntRange>>()
            val rendered = androidx.compose.ui.text.buildAnnotatedString {
                ranges = parts.mapIndexed { index, (span, text) ->
                    val start = length
                    append(text)
                    addStringAnnotation("source", index.toString(), start, length)
                    span to (start until length)
                }
                // This is an AnnotatedString.Builder, whose Object.toString() is not its text.
                val actualText = toAnnotatedString().text
                assertEquals(expectedText, actualText)
                paragraphs = poemParagraphs(actualText, ranges)
                paragraphs.forEach { paragraph ->
                    addStyle(androidx.compose.ui.text.ParagraphStyle(
                        textIndent = androidx.compose.ui.text.style.TextIndent(
                            paragraph.indent.em, paragraph.indent.em),
                        textDirection = when (paragraph.direction) {
                            "ltr" -> androidx.compose.ui.text.style.TextDirection.Ltr
                            "rtl" -> androidx.compose.ui.text.style.TextDirection.Rtl
                            else -> androidx.compose.ui.text.style.TextDirection.Content
                        }), paragraph.start, paragraph.end)
                }
            }
            assertEquals(expectedText, rendered.text)
            assertEquals(expectedParagraphs, paragraphs)
            assertEquals(expectedParagraphs.map { it.start to it.end },
                rendered.paragraphStyles.map { it.start to it.end })
            assertEquals(parts.size, rendered.getStringAnnotations("source", 0, rendered.length).size)
            ranges.forEachIndexed { index, (_, range) ->
                val annotation = rendered.getStringAnnotations("source", range.first, range.last + 1)
                    .single { it.item == index.toString() }
                assertEquals(range.first, annotation.start)
                assertEquals(range.last + 1, annotation.end)
                assertEquals(parts[index].second, rendered.text.substring(annotation.start, annotation.end))
            }
        }
        // Exact pre-shaping text from the failing device test's long Egyptian case.
        val long = "𓂜𓐰𓏏𓐱𓏭𓅪𓆑".repeat(12)
        assertTrue(long.length > 56)
        verify(listOf(Span("text", long, classes = "Egyp") to long), long, emptyList())
        verify(emptyList(), "", emptyList())
        verify(listOf(Span("text", "", classes = marker) to ""), "", emptyList())
        val unicode = "\u2066𓂜e\u0301  \u2069"
        verify(listOf(Span("link", "𓂜e\u0301", target = "word#Noun", trail = "  ",
            classes = marker, direction = "ltr") to unicode), unicode,
            listOf(PoemParagraph(0, unicode.length, 2, "ltr")))
        for ((text, expected) in listOf(
            "a" to listOf(PoemParagraph(0, 1, 2, "ltr")),
            "a\n" to listOf(PoemParagraph(0, 2, 2, "ltr")),
            "a\n\n" to listOf(PoemParagraph(0, 2, 2, "ltr"), PoemParagraph(2, 3, 0, "ltr")),
            "\n\n" to listOf(PoemParagraph(0, 1, 2, "ltr"), PoemParagraph(1, 2, 0, "ltr")),
            "𓂜\nb" to listOf(PoemParagraph(0, 3, 2, "ltr"), PoemParagraph(3, 4, 0, "ltr"))
        )) verify(listOf(Span("text", text, classes = marker) to text), text, expected)
        val markedBreak = Span("line_break", "", classes = marker)
        verify(listOf(markedBreak to "\n", markedBreak to "\n"), "\n\n",
            listOf(PoemParagraph(0, 1, 2, "ltr"), PoemParagraph(1, 2, 2, "ltr")))
    }

}
