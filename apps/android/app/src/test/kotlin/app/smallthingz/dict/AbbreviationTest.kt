package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class AbbreviationTest {
    private fun span(text: String, explanation: String = "") = Span("text", text, explanation = explanation)
    @Test fun contiguousStylesGroupWithoutChangingLabelsTargetsOrDistinctMeanings() {
        val spans = listOf(span("ab", "abbreviation"), span("br", "abbreviation").copy(italic = true),
            span(" / "), Span("link", "f", target = "gender", explanation = "feminine"), span(" / "), span("f", "forte"))
        val entry = Entry("Word", emptyList(), "language", "English", "en",
            listOf(Section(3, "Noun", listOf(Block("paragraph", 0, spans)))), emptyList())
        assertEquals(listOf("abbr", "f", "f"), entry.abbreviations.map { it.label })
        assertEquals(listOf("abbreviation", "feminine", "forte"), entry.abbreviations.map { it.explanation })
        assertEquals("abbr / f / f", textOf(spans)); assertEquals("gender", spans[3].target)
        assertEquals(spans, compactSpans(spans)); assertTrue(entry.abbreviations.all { it.context.startsWith("Noun: ") })
    }
    @Test fun authoredAudioCaptionIsGenericTextDetailWithoutChangingMediaOrLinkBody() {
        val file = "En-us-girl.ogg"
        val audio = Span("link", file, "File:$file",
            classes = "wikidict-media wikidict-media-file-456e2d75732d6769726c2e6f6767", explanation = "Audio (US)")
        val abbreviation = span("f", "feminine")
        val media = Media(file, "audio", file)
        val entry = Entry("girl", emptyList(), "language", "English", "en", listOf(
            Section(3, "Pronunciation", listOf(Block("paragraph", 0, listOf(audio)))),
            Section(3, "Noun", listOf(Block("paragraph", 0, listOf(abbreviation))))), emptyList(), media = listOf(media))
        assertEquals(listOf(file, "f"), entry.abbreviations.map { it.label })
        assertEquals(listOf("Audio (US)", "feminine"), entry.abbreviations.map { it.explanation })
        assertEquals(listOf("Pronunciation: $file", "Noun: f"), entry.abbreviations.map { it.context })
        assertEquals(listOf(media), MediaOwners(entry.media).embedded(listOf(audio)))
        assertEquals(file, textOf(entry.sections[0].blocks[0].spans))
        assertEquals("File:$file", entry.sections[0].blocks[0].spans.single().target)
        assertEquals(file, entry.media.single().caption)
        assertEquals(listOf(audio), compactSpans(listOf(audio)))
    }
    @Test fun collectionVisitsAllContainersAndKeepsStructuralAndEmptyAnnotationBoundaries() {
        val explained = listOf(span("f", "feminine"))
        val table = Table(explained, listOf(listOf(Cell(explained, false, 1, 1))))
        val entry = Entry("Word", explained, "language", "English", "en",
            listOf(Section(3, "Noun", listOf(Block("paragraph", 0, explained), Block("table", 0, emptyList(), table = table)))),
            listOf(Reference(1, 1, "", explained)), preamble = explained)
        assertEquals(6, entry.abbreviations.size); assertEquals(6, entry.abbreviations.map { it.context }.distinct().size)
        val separated = listOf(span("a", "same"), span(" "), span("b", "same"), Span("line_break", "", explanation = "same"), span("c", "same"))
        assertEquals(listOf("a", "b", "c"), entry.copy(displayTitle = separated, preamble = emptyList(), sections = emptyList(), references = emptyList()).abbreviations.map { it.label })
        assertTrue(entry.copy(displayTitle = emptyList(), preamble = emptyList(), sections = emptyList(), references = emptyList()).abbreviations.isEmpty())
        val trail = listOf(Span("line_break", "", trail = "tail", explanation = "meaning"))
        assertEquals(listOf("tail"), entry.copy(displayTitle = trail, preamble = emptyList(), sections = emptyList(), references = emptyList()).abbreviations.map { it.label })
    }
    @Test fun explainedNonlinkHeadingIsOneRichCompanionAndNotADuplicateBody() {
        val heading = Block("heading", 0, listOf(span("abbr", "abbreviation")), level = 3)
        val section = Section(3, "abbr", listOf(heading, Block("paragraph", 0, listOf(span("Body")))))
        assertSame(heading, sectionHeadingCompanion(section))
        val entry = Entry("Word", emptyList(), "language", "English", "en", listOf(section), emptyList())
        assertSame(heading, entry.readingRows.first().headingBlock); assertEquals(2, entry.readingRows.size)
        assertEquals(listOf("abbr"), entry.abbreviations.map { it.label })
    }
    @Test fun expandedAnnotationsOffsetBothSectionAndReferenceDestinations() {
        val spans = listOf(span("f", "feminine"), span(" / "), span("?", "uncertain"))
        val entry = Entry("Word", emptyList(), "language", "English", "en",
            listOf(Section(3, "Noun", listOf(Block("paragraph", 0, spans)))),
            listOf(Reference(1, 1, "", listOf(span("Reference")))), preamble = listOf(span("About")))
        assertEquals(2, entry.abbreviations.size)
        val closed = setOf("abbreviations")
        assertEquals(2, entryReadingStartIndex(entry, closed))
        assertEquals(4, entryReadingStartIndex(entry, emptySet()))
        assertEquals(5, referenceScrollIndex(entry, "#reference-1", closed))
        assertEquals(7, referenceScrollIndex(entry, "#reference-1", emptySet()))
        assertNull(referenceScrollIndex(entry, "#reference-2", emptySet()))
        assertEquals(1, entryReadingStartIndex(entry.copy(displayTitle = emptyList(), preamble = emptyList(), sections = emptyList(), references = emptyList()), emptySet()))
    }

}
