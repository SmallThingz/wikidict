package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

internal object ReferenceLayoutFixture {
    val font = InlineFontSnapshot(.9f, FontScaleBasis.NormalBody, fontNormalized = true)
    private val zero = StyleLength(StyleLengthUnit.Px, 0f)
    private val margin = SignedContainerMargin(StyleLengthUnit.Em, 1f)
    val box = ContainerStyle(margins = SignedContainerEdges(margin, margin, margin, margin),
        padding = StyleEdges(zero, zero, zero, zero), border = ContainerBorder.None,
        background = ContainerColor.Transparent, layout = ContainerLayout.Flow,
        clear = FigureClear.None, overflow = ContainerOverflow.Visible, ownerFont = font,
        lineHeight = ContainerLineHeight.Normal)
    val item = ReferenceItemLayout(box, ReferenceListMarker.DecimalOutside, FigureColor.Rgb("#123456"),
        ReferenceBacklinkPrefix.SingleSpace, ContainerColor.Rgb("#ffeeaa"))
    val markerA = Span("link", "[A]", targetFragment = "reference-10", role = "reference",
        citationMarker = CitationMarker(10, 7, "return-A"))
    val markerB = Span("link", "[B]", targetFragment = "reference-20", role = "reference",
        citationMarker = CitationMarker(20, 8, "return-B"))
    val references = listOf(10L, 20L).mapIndexed { index, number ->
        Reference(number, (index + 3).toLong(), "", listOf(Span("text", "note $number "),
            Span("external_link", "source", "https://example.test/$number", tooltip = "kept")),
            bodyTypography = BodyTypography(font, ContainerLineHeight.Normal, BidiResolvedDirection.Ltr),
            backlinks = listOf(ReferenceBacklink.withPolicies(if (index == 0) 7L else 8L,
                Span("link", "return", targetFragment = if (index == 0) "return-A" else "return-B",
                    fontScale = .75f, fontScaleBasis = FontScaleBasis.NormalBody))))
    }
    val layout = ReferenceBatchLayout(box, box, listOf(item, item))
    val batch = ReferenceBatchPlacement(0, 1, listOf(1, 0), layout)
}

class ReferenceLayoutTest {
    private val f = ReferenceLayoutFixture
    private fun refuses(body: () -> Unit) {
        try { body(); fail("Invalid reference layout accepted") } catch (_: IllegalArgumentException) { }
    }
    @Test fun completeProjectionPreservesOrderOriginalBodiesIndependentBacklinkAndSpaceFont() {
        val projected = referenceLayoutProjection(f.batch, f.references, "batch")
        val paragraphs = projected.paragraphs.values.toList()
        assertEquals(listOf(1, 0), paragraphs.map { it.referenceIndex })
        assertEquals(listOf("4.", "3."), paragraphs.map { it.marker })
        assertSame(f.references[1], paragraphs[0].reference)
        paragraphs.forEach { paragraph ->
            assertSame(paragraph.reference.backlinks.single().span, paragraph.spans[0])
            assertEquals(" ", paragraph.spans[1].text)
            assertEquals(f.font, f.item.box.ownerFont)
            assertEquals(.9f, paragraph.spans[1].fontScale)
            assertEquals(.75f, paragraph.spans[0].fontScale)
            paragraph.reference.spans.indices.forEach { assertSame(paragraph.reference.spans[it], paragraph.spans[it + 2]) }
        }
        val wrapper = projected.blocks.single().container!!
        val list = wrapper.blocks.single().container!!
        assertEquals(f.box, wrapper.style); assertEquals(f.box, list.style)
        assertEquals(2, list.blocks.size)
        assertEquals(f.box, list.blocks[0].container!!.style)
        assertEquals(2, f.references.size) // Catalog order remains A then B, despite B-first flush.
        assertEquals(listOf(10L, 20L), f.references.map { it.number })
    }
    @Test fun targetChangesOnlySelectedItemBackgroundWithoutChangingFontsOrSource() {
        val ordinary = referenceLayoutProjection(f.batch, f.references, "batch")
        val target = referenceLayoutProjection(f.batch, f.references, "batch", 0)
        fun boxes(value: ReferenceLayoutProjection) = value.blocks.single().container!!.blocks.single().container!!.blocks
            .map { it.container!!.style }
        assertEquals(boxes(ordinary)[0], boxes(target)[0])
        assertEquals(boxes(ordinary)[1].copy(background = f.item.targetBackground), boxes(target)[1])
        assertEquals(ordinary.paragraphs, target.paragraphs)
    }
    @Test fun outsideMarkersUseActualAdvanceBaselineAndPhysicalDirectionWithoutContentInset() {
        val left = referenceMarkerAnchor(40f, 200f, 17.25f, 31f, false)
        assertEquals(40f, left.x); assertEquals(22.75f, left.left); assertEquals(40f, left.right)
        assertTrue(left.rightAligned); assertEquals(31f, left.baseline)
        val right = referenceMarkerAnchor(40f, 200f, 17.25f, 31f, true)
        assertEquals(200f, right.x); assertEquals(217.25f, right.right)
        assertFalse(right.rightAligned); assertEquals(31f, right.baseline)
        refuses { referenceMarkerAnchor(40f, 200f, Float.NaN, 31f, false) }
    }
    @Test fun layoutRefusesMissingOwnerMismatchedFontLeadingWhitespaceAndIncompleteItems() {
        refuses { validateReferenceBatchLayout(f.layout.copy(items = listOf(f.item)), f.batch.referenceIndices, f.references) }
        refuses { validateReferenceBatchLayout(f.layout.copy(wrapper = f.box.copy(ownerFont = null)), f.batch.referenceIndices, f.references) }
        refuses { validateReferenceBatchLayout(f.layout.copy(items = listOf(f.item.copy(box = f.box.copy(ownerFont = f.font.copy(fontScale = 1f))), f.item)), f.batch.referenceIndices, f.references) }
        for (prefix in listOf("", " ", "\t", "\n", "\r", "\u000c")) {
            val refs = f.references.toMutableList(); refs[1] = refs[1].copy(spans = listOf(Span("text", prefix)))
            refuses { validateReferenceBatchLayout(f.layout, f.batch.referenceIndices, refs) }
        }
        assertTrue(referenceLayoutBodyStartsText(listOf(Span("link", "visible", "kept"))))
    }
    @Test fun groupedPlacementKeepsLegacyRowsAndEachOriginalReferenceNavigation() {
        val section = Section(2, "Body", listOf(Block("paragraph", depth = 0, spans = listOf(f.markerA, f.markerB, Span("text", "body")))))
        val entry = Entry("word", emptyList(), "language", "English", "en", listOf(section), f.references,
            referenceBatches = listOf(f.batch))
        assertEquals(1, entry.readingRows.count { it.referenceBatch != null })
        val folded = setOf("heading-0")
        assertEquals(setOf("heading-0"), referenceFoldKeys(entry, 0))
        assertEquals(referenceItemScrollIndex(entry, 0, emptySet()), referenceItemScrollIndex(entry, 1, emptySet()))
        assertNull(referenceItemScrollIndex(entry, 0, folded))
        val legacy = entry.copy(referenceBatches = listOf(f.batch.copy(layout = null)))
        assertEquals(listOf(20L, 10L), legacy.readingRows.mapNotNull { it.reference?.number })
        assertTrue(legacy.readingRows.none { it.referenceBatch != null })
        val ordinary = entry.copy(bodyAdjoining = BodyAdjoiningPolicy.Ordinary)
        val batchIndex = ordinary.readingRows.indexOfFirst { it.referenceBatch != null }
        val run = floatBodyRuns(ordinary.readingRows, ordinary.bodyAdjoining, ordinary.language).single()
        assertTrue(batchIndex in run)
        assertTrue(ordinary.readingRows.indexOfFirst { it.block != null } in run)
        assertEquals(entryReadingStartIndex(ordinary, emptySet()) + run.first,
            referenceItemScrollIndex(ordinary, 0, emptySet()))
        refuses { legacy.copy(bodyAdjoining = BodyAdjoiningPolicy.Ordinary) }
    }
    @Test fun boundaryZeroPrecedesRichCompanionButNotMetadataHeadingAndKeepsOwnFold() {
        val rich = Section(2, "Rich", listOf(Block("heading", depth = 0, level = 2,
            spans = listOf(Span("link", "Rich", "heading-target"))), Block("paragraph", depth = 0, spans = listOf(Span("text", "body")))))
        val batch = f.batch.copy(sectionIndex = 1, beforeBlockIndex = 0)
        val previous = Section(2, "Previous", listOf(Block("paragraph", depth = 0, spans = listOf(Span("text", "previous")))))
        fun rows(section: Section, placement: ReferenceBatchPlacement) = readingRows(listOf(previous, section),
            references = f.references, referenceBatches = listOf(placement))
        val compiled = rows(rich, batch)
        val batchIndex = compiled.indexOfFirst { it.referenceBatch != null }
        assertTrue(batchIndex < compiled.indexOfFirst { it.key == "heading-1" })
        assertTrue(visibleReadingRows(compiled, setOf("heading-0")).any { it.referenceBatch != null })
        assertFalse(visibleReadingRows(compiled, setOf("heading-1")).any { it.referenceBatch != null })
        val metadata = rows(rich.copy(blocks = rich.blocks.drop(1)), batch)
        assertTrue(metadata.indexOfFirst { it.key == "heading-1" } < metadata.indexOfFirst { it.referenceBatch != null })
        val legacy = rows(rich, batch.copy(layout = null))
        assertTrue(legacy.indexOfFirst { it.key == "heading-1" } < legacy.indexOfFirst { it.referenceIndex != null })
        assertEquals(listOf(1, 0), legacy.mapNotNull { it.referenceIndex })
        val nullFirst = f.batch.copy(sectionIndex = 0, beforeBlockIndex = 0, layout = null)
        val unrelated = readingRows(listOf(rich, rich), references = f.references,
            referenceBatches = listOf(nullFirst, batch))
        assertTrue(unrelated.indexOfFirst { it.key == "heading-0" } < unrelated.indexOfFirst { it.referenceIndex != null })
        assertTrue(unrelated.indexOfFirst { it.referenceBatch != null } < unrelated.indexOfFirst { it.key == "heading-1" })
        val sameBoundary = readingRows(listOf(rich), references = f.references,
            referenceBatches = listOf(nullFirst.copy(referenceIndices = listOf(0)),
                f.batch.copy(beforeBlockIndex = 0, referenceIndices = listOf(1),
                    layout = f.layout.copy(items = listOf(f.item)))))
        assertEquals(listOf("reference-item-0", "reference-batch-1", "heading-0"), sameBoundary.take(3).map { it.key })
        val manySections = List(40) { rich }
        val batches = manySections.indices.map { f.batch.copy(sectionIndex = it, beforeBlockIndex = 0) }
        var reads = 0
        val counted = object : AbstractList<ReferenceBatchPlacement>() {
            override val size get() = batches.size
            override fun get(index: Int): ReferenceBatchPlacement { reads++; return batches[index] }
        }
        val manyRows = readingRows(manySections, references = f.references, referenceBatches = counted)
        assertEquals(batches.size, manyRows.count { it.referenceBatch != null })
        assertTrue("Ordered batches must be visited a bounded number of times: $reads", reads <= batches.size * 10)
    }

}
