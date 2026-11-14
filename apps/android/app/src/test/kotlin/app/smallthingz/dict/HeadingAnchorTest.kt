package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream

class HeadingAnchorTest {
    private fun wire(version: Int, blockKind: Int = 9,
        blockAnchor: ByteArray = "Noun_3".toByteArray(), anchorLength: Int = blockAnchor.size,
        blockFallback: ByteArray = "Noun_legacy_3".toByteArray(), fallbackLength: Int = blockFallback.size): ByteArray {
        val out = ByteArrayOutputStream()
        fun byte(value: Int) { out.write(value) }
        fun u32(value: Int) { repeat(4) { byte(value ushr (it * 8) and 255) } }
        fun string(value: String) { val bytes = value.toByteArray(Charsets.UTF_8); u32(bytes.size); out.write(bytes) }
        out.write("DPR$version".toByteArray())
        u32(0) // Display title.
        u32(1); byte(3); string("Noun")
        if (version >= 5) { string("Noun_2"); string("Noun_legacy_2") }
        u32(1); byte(blockKind); byte(0); byte(4)
        u32(1); byte(0); byte(0); byte(0)
        listOf("Nested heading", "", "", "", "", "").forEach(::string)
        if (version >= 3) string("Compiled explanation")
        if (version >= 4) { byte(1); string("#123456") }
        byte(0); string(""); string(""); byte(0)
        if (version >= 5) {
            u32(anchorLength); out.write(blockAnchor)
            u32(fallbackLength); out.write(blockFallback)
        }
        repeat(5) { u32(0) } // Preamble, organization, unclassified sections, references, media.
        return out.toByteArray()
    }

    private fun decode(bytes: ByteArray) = BlobDecoder.decode(bytes, "word", "language", "English", "en")

    @Test fun dpr5PreservesCompiledSectionAndStandaloneHeadingIdsAndEarlierSpanFields() {
        val entry = decode(wire(5))
        val section = entry.sections.single()
        val heading = section.blocks.single()
        assertEquals("Noun_2", section.anchor)
        assertEquals("Noun_3", heading.anchor)
        assertEquals("Noun_legacy_2", section.anchorFallback)
        assertEquals("Noun_legacy_3", heading.anchorFallback)
        assertEquals("Compiled explanation", heading.spans.single().explanation)
        assertEquals("#123456", heading.spans.single().foreground)
        assertEquals("heading-0", headingScrollKey(entry, "#Noun_2"))
        assertEquals("block-0-0", headingScrollKey(entry, "#Noun_3"))
        assertEquals("heading-0", headingScrollKey(entry, "#Noun_legacy_2"))
        assertEquals("block-0-0", headingScrollKey(entry, "#Noun_legacy_3"))
        for (version in 2..4) {
            val legacy = decode(wire(version))
            assertEquals("", legacy.sections.single().anchor)
            assertEquals("", legacy.sections.single().blocks.single().anchor)
            assertEquals("", legacy.sections.single().anchorFallback)
            assertEquals("", legacy.sections.single().blocks.single().anchorFallback)
            assertEquals("heading-0", headingScrollKey(legacy, "#Noun"))
        }
    }

    @Test fun dpr5RejectsNonHeadingIdsMalformedUtf8AndOutOfBoundsAnchorLengths() {
        assertThrows(Exception::class.java) { decode(wire(5, blockKind = 0)) }
        assertThrows(Exception::class.java) { decode(wire(5, blockAnchor = byteArrayOf(0xc3.toByte()))) }
        assertThrows(Exception::class.java) { decode(wire(5, anchorLength = Int.MAX_VALUE)) }
        assertThrows(Exception::class.java) { decode(wire(5, blockFallback = byteArrayOf(0xc3.toByte()))) }
        assertThrows(Exception::class.java) { decode(wire(5, fallbackLength = Int.MAX_VALUE)) }
        assertThrows(Exception::class.java) { decode(wire(5, blockKind = 0, blockAnchor = byteArrayOf())) }
        assertThrows(Exception::class.java) { decode(wire(5).copyOf(wire(5).size - 1)) }
        assertEquals("", decode(wire(5, blockKind = 0, blockAnchor = byteArrayOf(), blockFallback = byteArrayOf())).sections.single().blocks.single().anchor)
    }

    @Test fun compiledIdsSurviveOwnerFilteringAndPresentationOrderWithoutInventingOrdinals() {
        val entry = Entry("word", emptyList(), "language", "English", "en", listOf(
            Section(3, "Noun", emptyList(), anchor = "Noun_3"),
            Section(3, "Noun 2", emptyList(), anchor = "Noun_2_2"),
            Section(3, "Noun", emptyList(), anchor = "Noun_2"),
            Section(3, "Usage notes", emptyList(), anchor = "Usage_notes"),
        ), emptyList())
        assertEquals("heading-2", headingScrollKey(entry, "#Noun_2"))
        assertEquals("heading-2", headingScrollKey(entry, "#Noun 2"))
        assertEquals("heading-0", headingScrollKey(entry, "#Noun_3"))
        assertEquals("heading-1", headingScrollKey(entry, "#Noun_2_2"))
        assertEquals("heading-3", headingScrollKey(entry, "#Usage notes"))
        assertNull(headingScrollKey(entry, "#Noun")) // The earlier owner's Noun is absent.
        assertNull(headingScrollKey(entry, "#Usage%20notes"))
        assertNull(headingScrollKey(entry, "#Usage.20notes"))
        assertNull(headingScrollKey(entry, "word#Noun_2"))
    }

    @Test fun sourceRetainedLegacyTargetsMatchFallbackIdsWithoutUnescapingOrRecounting() {
        // The compiler retains the authored [[#.C3.A4]] link target literally.
        val source = Span("link", "Read legacy heading", target = "#.C3.A4")
        val entry = Entry("word", emptyList(), "language", "English", "en", listOf(
            Section(3, "Source", listOf(Block("definition", 1, listOf(source))), anchor = "Source"),
            Section(3, "\u00e4", emptyList(), anchor = "\u00e4", anchorFallback = ".C3.A4"),
            Section(3, ".C3.A4", emptyList(), anchor = ".C3.A4_2"),
            Section(3, "\u00e4", emptyList(), anchor = "\u00e4_2", anchorFallback = ".C3.A4_3"),
        ), emptyList())
        assertEquals("#.C3.A4", entry.sections.first().blocks.single().spans.single().target)
        assertEquals("heading-1", headingScrollKey(entry, source.target))
        assertEquals("heading-1", headingScrollKey(entry, "#\u00e4"))
        assertEquals("heading-2", headingScrollKey(entry, "#.C3.A4_2"))
        assertEquals("heading-3", headingScrollKey(entry, "#.C3.A4_3"))
        assertEquals("heading-3", headingScrollKey(entry, "#\u00e4_2"))
        assertNull(headingScrollKey(entry, "#%C3%A4"))
        assertNull(headingScrollKey(entry.copy(sections = listOf(entry.sections[2])), "#.C3.A4"))
    }

    @Test fun legacyLabelsRequireUniqueDestinationsWithoutCompiledIdsAndCompanionsCountOnce() {
        val legacy = Entry("word", emptyList(), "language", "English", "en", listOf(
            Section(3, "Noun", emptyList()), Section(3, "Noun", emptyList()),
            Section(3, "Usage notes", emptyList()),
        ), emptyList())
        assertNull(headingScrollKey(legacy, "#Noun"))
        assertEquals("heading-2", headingScrollKey(legacy, "#Usage_notes"))
        assertNull(headingScrollKey(legacy.copy(sections = listOf(
            Section(3, "Usage notes", emptyList(), anchor = "Usage_notes_2"))), "#Usage_notes"))
        val heading = Block("heading", 0, listOf(Span("link", "Noun", target = "other")), level = 3, anchor = "Noun_2", anchorFallback = "Noun_legacy_2")
        val companion = legacy.copy(sections = listOf(Section(3, "Noun", listOf(heading), anchor = "Noun_2", anchorFallback = "Noun_legacy_2")))
        assertEquals(1, companion.readingRows.size)
        assertEquals("heading-0", headingScrollKey(companion, "#Noun_2"))
        assertEquals("heading-0", headingScrollKey(companion, "#Noun_legacy_2"))
    }

    @Test fun sourceRevealKeepsTheMatchedIdentityAndOneSelectedOutsetThroughHeadingDestination() {
        fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
        val zero = StyleEdges(px(0f), px(0f), px(0f), px(0f))
        val policy = SectionHeadingStyle(ContainerStyle(margins = zero, padding = zero,
            border = ContainerBorder.None, ownerFontScale = 1f, lineHeight = ContainerLineHeight.Normal,
            clear = FigureClear.None, fontFamily = ContainerFontFamily.SansSerif),
            InlineFontSnapshot(1f, FontScaleBasis.NormalBody, language = "th"), BidiResolvedDirection.Ltr,
            anchorReveal = HeadingAnchorReveal(px(75f), px(0f)))
        val companion = Block("heading", 0, listOf(Span("link", "Heading", "action")),
            level = 3, anchor = "owner_id", anchorFallback = ".6Fwner")
        val section = Section(3, "Heading", listOf(companion), "owner_id", ".6Fwner", policy)
        val entry = Entry("word", emptyList(), "language", "Thai", "th", listOf(section), emptyList())
        val primary = checkNotNull(headingDestination(entry, "#owner id"))
        val fallback = checkNotNull(headingDestination(entry, "#.6Fwner"))
        assertEquals(primary.rowKey, fallback.rowKey)
        assertEquals(HeadingAnchorSelection("owner_id", HeadingAnchorKind.Primary, px(75f)), primary.anchorMatch)
        assertEquals(HeadingAnchorSelection(".6Fwner", HeadingAnchorKind.Fallback, px(0f)), fallback.anchorMatch)
        assertSame(companion, entry.readingRows.single().headingBlock)
        assertSame(companion.spans.single(), entry.readingRows.single().headingBlock!!.spans.single())
        assertNull(headingDestination(entry, "#%6Fwner"))
        val duplicate = entry.copy(sections = listOf(section, Section(3, "Other", emptyList(), ".6Fwner")))
        assertNull(headingDestination(duplicate, "#.6Fwner"))
        val legacy = entry.copy(sections = listOf(section.copy(headingStyle = null)))
        assertNull(headingDestination(legacy, "#owner_id")!!.anchorMatch!!.revealTop)
        assertNull(headingDestination(legacy, "#.6Fwner")!!.anchorMatch!!.revealTop)
        assertNull(headingDestination(entry.copy(sections = listOf(Section(3, "Heading", emptyList()))),
            "#Heading")!!.anchorMatch)
    }

    @Test fun sourceRevealConvertsOnlyTheSelectedCssPixelsBeforeOrdinaryScrollClamping() {
        val primary = StyleLength(StyleLengthUnit.Px, 75f)
        val fallback = StyleLength(StyleLengthUnit.Px, 0f)
        assertEquals(196.75f, headingRevealScrollDelta(300.5f, 10f, primary, 1.25f)!!, 0f)
        assertEquals(290.5f, headingRevealScrollDelta(300.5f, 10f, fallback, 1.25f)!!, 0f)
        assertEquals(-93.75f, headingRevealScrollDelta(10f, 10f, primary, 1.25f)!!, 0f)
        assertEquals(-1_000_000f, headingRevealScrollDelta(0f, 0f,
            StyleLength(StyleLengthUnit.Px, 1_000_000f), 1f)!!, 0f)
        assertNull(headingRevealScrollDelta(Float.NaN, 0f, primary, 1f))
        assertNull(headingRevealScrollDelta(0f, Float.POSITIVE_INFINITY, primary, 1f))
        assertNull(headingRevealScrollDelta(0f, 0f, primary, 0f))
        assertNull(headingRevealScrollDelta(0f, 0f, StyleLength(StyleLengthUnit.Em, 1f), 1f))
        assertNull(headingRevealScrollDelta(0f, 0f, StyleLength(StyleLengthUnit.Px, Float.MAX_VALUE), 2f))
    }

}
