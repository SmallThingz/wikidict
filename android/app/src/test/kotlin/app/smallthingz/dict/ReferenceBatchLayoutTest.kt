package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class ReferenceBatchLayoutTest {
    private fun text(value: String) = Span("text", value)
    private fun paragraph(value: String) = Block("paragraph", 0, listOf(text(value)))
    private fun note(number: Long) = Reference(number, number, "", listOf(text("note-$number")))

    @Test fun explicitReferenceRowsResolveOriginalBoundariesBeforeCompactionAndKeepSourceOrder() {
        val companion = Block("heading", 0, listOf(Span("link", "Body", "Original heading")), level = 2)
        val blank = Block("blank", 0, emptyList())
        val body = paragraph("kept body")
        val references = listOf(note(1), note(2), note(3), note(4))
        val batches = listOf(ReferenceBatchPlacement(0, 0, listOf(2)),
            ReferenceBatchPlacement(0, 0, listOf(0)), ReferenceBatchPlacement(0, 2, listOf(3)),
            ReferenceBatchPlacement(1, 0, listOf(1)))
        val entry = Entry("Placement", emptyList(), "language", "English", "en",
            listOf(Section(2, "Body", listOf(companion, blank, body)), Section(2, "References", emptyList())),
            references, referenceBatches = batches)
        assertSame(references, entry.references)
        assertEquals(listOf("heading-0", "reference-item-2", "reference-item-0", "reference-item-3", "block-0-2", "heading-1", "reference-item-1"), entry.readingRows.map { it.key })
        assertSame(companion, entry.readingRows.first().headingBlock)
        assertSame(body, entry.readingRows.single { it.block != null }.block)
        assertEquals(listOf(2, 0, 3, 1), entry.readingRows.mapNotNull { it.referenceIndex })
        entry.readingRows.filter { it.reference != null }.forEach { assertSame(references[it.referenceIndex!!], it.reference) }
        assertNull(metadataReferenceHeadingKey(entry))
        assertTrue(visibleEntryReadingRows(entry, emptySet()).any { it.heading?.title == "References" })
        val legacy = entry.copy(referenceBatches = null)
        assertTrue(legacy.readingRows.none { it.reference != null })
        assertEquals("heading-1", metadataReferenceHeadingKey(legacy))
        assertEquals(references, legacy.references)
        val duplicateNumbers = entry.copy(references = listOf(references[0], references[0], references[2], references[3]))
        assertEquals(4, duplicateNumbers.readingRows.mapNotNull { if (it.reference != null) it.key else null }.distinct().size)
        assertNull(referenceTargetIndex(duplicateNumbers, "#reference-1"))
        assertEquals(0, referenceTargetIndex(duplicateNumbers.copy(referenceBatches = null), "#reference-1"))
    }

    @Test fun explicitReferenceNavigationOpensTheOwningSectionAndPreservesMarkersBacklinksAndHeadings() {
        fun marker(occurrence: Long) = Span("link", "[A]", role = "reference", targetFragment = "reference-10",
            citationMarker = CitationMarker(10, occurrence, "return-$occurrence"))
        val first = marker(1); val inB = marker(2)
        val noteA = Reference(10, 1, "A", emptyList(), blocks = listOf(
            Block("heading", 0, listOf(text("Inside note")), level = 3, anchor = "inside-note"), paragraph("A body")),
            backlinks = listOf(2L, 1L).map { ReferenceBacklink.withPolicies(it, Span("link", "return-$it", targetFragment = "return-$it")) })
        val noteB = Reference(20, 1, "B", listOf(inB, text(" B body")))
        val entry = Entry("Navigation", emptyList(), "language", "English", "en", listOf(Section(2, "Body", listOf(
            Block("paragraph", 0, listOf(first)), Block("definition", 1, listOf(text("meaning")), number = "1")))),
            listOf(noteA, noteB), referenceBatches = listOf(ReferenceBatchPlacement(0, 1, listOf(1, 0))))
        val folded = mutableSetOf("heading-0", "heading-0-details", "references")
        assertNull(referenceScrollIndex(entry, "#reference-20", folded))
        assertEquals(setOf("heading-0", "heading-0-details"), referenceFoldKeys(entry, 1))
        folded.removeAll(referenceFoldKeys(entry, 1))
        val rows = visibleEntryReadingRows(entry, folded)
        assertEquals(entryReadingStartIndex(entry, folded) + rows.indexOfFirst { it.referenceIndex == 1 }, referenceScrollIndex(entry, "#reference-20", folded))
        assertTrue(referenceScrollIndex(entry, "#reference-20", folded)!! < referenceScrollIndex(entry, "#reference-10", folded)!!)
        assertNull(referenceScrollIndex(entry, "#reference-99", folded))
        val destinations = citationDestinations(entry)
        val body = destinations.getValue("return-1"); val note = destinations.getValue("return-2")
        assertSame(first, body.span); assertSame(inB, note.span)
        assertEquals(CitationSourceSlot.Reference, note.slot)
        assertEquals(1, note.referenceIndex)
        assertEquals(referenceFoldKeys(entry, 1), citationFoldKeys(entry, note))
        assertEquals(referenceItemScrollIndex(entry, 1, folded), citationScrollIndex(entry, note, folded))
        assertEquals(2, citationScrollIndex(entry, body, folded))
        val heading = checkNotNull(headingDestination(entry, "#inside-note"))
        assertEquals(0, heading.referenceIndex)
        assertEquals("reference-10/block-0", heading.path)
        assertEquals(listOf(2L, 1L), entry.references[0].backlinks.map { it.occurrence })
        assertEquals(listOf(EntryLink("", "return-2"), EntryLink("", "return-1")), entry.references[0].backlinks.map { it.span.entryLink() })
        val legacy = entry.copy(referenceBatches = null)
        assertEquals(setOf("references"), referenceFoldKeys(legacy, 1))
        assertEquals(metadataReferencesStartIndex(legacy, folded) + 2, referenceItemScrollIndex(legacy, 1, folded))

        // Different groups may share displayed numbers; only the original item owns a heading reveal.
        val duplicateNotes = listOf("A", "B").map { group -> Reference(7, 1, group, emptyList(), blocks = listOf(
            Block("heading", 0, listOf(text("Only $group")), level = 3, anchor = "only-$group"))) }
        val duplicates = Entry("Duplicate numbers", emptyList(), "language", "English", "en",
            listOf(Section(2, "Body", emptyList())), duplicateNotes,
            referenceBatches = listOf(ReferenceBatchPlacement(0, 0, listOf(1, 0))))
        for ((index, group) in listOf("A", "B").withIndex()) {
            val selected = checkNotNull(headingDestination(duplicates, "#only-$group"))
            assertEquals(index, selected.referenceIndex)
            assertEquals("reference-item-$index", selected.rowKey)
            assertEquals("reference-7/block-0", selected.path)
            val request = CellHeadingRequest(checkNotNull(selected.path), selected.anchorMatch,
                referenceIndex = selected.referenceIndex)
            assertSame(request, referenceHeadingRequest(request, index))
            assertNull(referenceHeadingRequest(request, 1 - index))
            assertSame(request, referenceHeadingRequest(request, null)) // legacy footer remains unchanged
            assertNull(referenceHeadingRequest(CellHeadingRequest(request.path), index))
            assertSame(duplicateNotes[index], duplicates.references[index])
        }
    }

    @Test fun explicitReferenceItemsSeparateNativeFloatRunsWithoutInventingBlocksOrBodyPolicy() {
        val before = Block("container", 0, emptyList(), container = Container(listOf(paragraph("before")), ContainerStyle()))
        val after = Block("container", 0, emptyList(), container = Container(listOf(paragraph("after")), ContainerStyle()))
        val entry = Entry("Native boundaries", emptyList(), "language", "English", "en",
            listOf(Section(2, "Body", listOf(before, after))), listOf(note(1)),
            referenceBatches = listOf(ReferenceBatchPlacement(0, 1, listOf(0))))
        val rows = visibleEntryReadingRows(entry, emptySet())
        val reference = rows.indexOfFirst { it.reference != null }
        val runs = floatBodyRuns(rows)
        assertEquals(listOf(1..1, 3..3), runs)
        assertFalse(runs.any { reference in it })
        assertEquals(listOf(before, after), rows.mapNotNull { it.block })
        assertTrue(rows[reference].heading == null && rows[reference].block == null)
        assertNull(entry.bodyAdjoining)
        assertTrue(runCatching { entry.copy(bodyAdjoining = BodyAdjoiningPolicy.Ordinary) }.isFailure)
        assertEquals(listOf(1..2), floatBodyRuns(entry.copy(referenceBatches = null).readingRows))
    }
}
