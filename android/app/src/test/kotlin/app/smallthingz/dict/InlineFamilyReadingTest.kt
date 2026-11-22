package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** API05 typed synthetic owners. No source issuance or native font availability claim. */
class InlineFamilyReadingTest {
    private val serif = ContainerFontFamily.Stack(listOf("Absent family"), GenericFontFamily.Serif)
    private fun zero() = StyleLength(StyleLengthUnit.Px, 0f)
    private fun edges() = StyleEdges(zero(), zero(), zero(), zero())
    private fun heading(): Section {
        val box = ContainerStyle(margins = edges(), padding = edges(),
            border = ContainerBorder.None, background = ContainerColor.Transparent,
            ownerFontScale = 1f, lineHeight = ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Px, 20f)),
            fontFamily = ContainerFontFamily.SansSerif, clear = FigureClear.None)
        return Section(2, "Owner", listOf(Block("heading", 0, listOf(Span("text", "Owner")), level = 2)),
            headingStyle = SectionHeadingStyle(box,
                InlineFontSnapshot(fontScale = 1f, fontScaleBasis = FontScaleBasis.NormalBody, language = "th"),
                BidiResolvedDirection.Ltr))
    }

    @Test fun explicitFamilyPreservesWholeOwnerAndOriginalDenseBlock() {
        val source = listOf(Span("text", "  "), Span("link", "A", "target", trail = "  ", fontFamily = serif),
            Span("text", "\u00a0  "))
        val block = Block("paragraph", 0, source)
        assertSame(source, compactSpans(source))
        assertSame(source, ordinaryInlineDisplaySpans(block))
        assertSame(source, paragraphDisplaySpans(block))
        val dense = block.copy(spans = buildList {
            addAll(source)
            repeat(40) { add(Span("line_break", "")); add(Span("text", "  next  ")) }
        })
        val rows = readingRows(listOf(Section(1, "Other", listOf(dense))))
        assertEquals(listOf("heading-0", "block-0-0"), rows.map { it.key })
        assertSame(dense, rows.last().block)
        val legacy = source.map { it.copy(fontFamily = null) }
        assertNotEquals(legacy, compactSpans(legacy))
        assertFalse(legacy.hasAuthoredFontFamily())
        val poem = source.map { it.copy(classes = "wikidict-poem wikidict-poem-indent-1") }
        assertSame(poem, paragraphDisplaySpans(Block("paragraph", 0, poem)))
    }

    @Test fun declaringSnapshotOwnsIndependentFamilyAndPreservesNeighbours() {
        val snapshot = InlineFontSnapshot(fontScale = 1f, fontScaleBasis = FontScaleBasis.NormalBody,
            code = true, language = "th", fontFamily = serif)
        val child = Span("text", "child", small = true, fontFamily = ContainerFontFamily.SansSerif,
            inlineStyle = InlineTextStyle(lineHeight = InlineLineHeight.FontRelative(1.5f, snapshot)))
        val source = listOf(Span("text", "  "), child.copy(fontFamily = null), Span("text", "  "))
        assertTrue(source.hasAuthoredFontFamily())
        assertSame(source, paragraphDisplaySpans(Block("paragraph", 0, source)))
        val probe = inlineFontSnapshotSpan(snapshot)
        assertEquals(serif, probe.fontFamily)
        assertNull(probe.legacyFontFamily())
        assertEquals(ContainerFontFamily.SansSerif, inlineMetricOwnerSpan(child).fontFamily)
        assertEquals(LegacySpanFontFamily.Code, probe.copy(fontFamily = null).legacyFontFamily())
        assertEquals(LegacySpanFontFamily.Egyptian, Span("text", "x", classes = "Egyp").legacyFontFamily())
        assertNull(Span("text", "x", code = true, classes = "Egyp", fontFamily = serif).legacyFontFamily())
    }

    @Test fun familyOnlyEmptyOwnerDoesNotInventContentButRealSpaceAndMetricsRemain() {
        val empty = Block("paragraph", 0, listOf(Span("text", "", fontFamily = serif)))
        assertSame(empty.spans, paragraphDisplaySpans(empty))
        assertFalse(paragraphHasContent(empty))
        assertFalse(paragraphHasContent(empty.copy(spans = emptyList()), preserveCompiledText = true))
        assertTrue(paragraphHasContent(empty.copy(spans = listOf(Span("text", "  "))), preserveCompiledText = true))
        assertTrue(paragraphHasContent(empty.copy(spans = listOf(Span("text", "", fontFamily = serif,
            inlineStyle = InlineTextStyle(lineHeight = InlineLineHeight.Computed(
                InlineComputedLength(20f, FontScaleBasis.NormalBody))))))))
    }

    @Test fun headingOnlyRealPrefixStartsAtFirstBlockWithoutOrdinaryMarginGrant() {
        val first = Block("paragraph", 0, listOf(Span("text", "  prefix  ")), style = BlockStyle(margins = edges()))
        val float = Block("table", 0, emptyList(), table = Table(emptyList(), emptyList(),
            style = TableStyle(floatSide = TableFloatSide.Right)))
        val prefix = Section(0, "", listOf(first, float))
        val sections = listOf(prefix, heading())
        val rows = readingRows(sections)
        assertSame(first, rows[1].block)
        assertEquals(listOf("heading-0", "block-0-0", "block-0-1", "heading-1"), rows.map { it.key })
        assertEquals(listOf(1..3), floatBodyRuns(rows))
        assertFalse(sectionHeadingVisible(prefix, "Thai"))
        assertFalse(sectionInContents(prefix, "Thai"))
        val folded = visibleReadingRows(rows, setOf("heading-1"))
        assertSame(first, folded[1].block)
        assertEquals(listOf(1..3), floatBodyRuns(folded))
        val legacy = readingRows(listOf(prefix, heading().copy(headingStyle = null)))
        assertEquals(2, floatBodyRuns(legacy).single().first)
        assertEquals(1, floatBodyRuns(legacy, BodyAdjoiningPolicy.Ordinary).single().first)
    }

    @Test fun compiledWhitespaceHeadingRetainsInitialAndExplicitFoldSemantics() {
        val source = heading()
        val body = Block("paragraph", 0, listOf(Span("link", "body", "target")))
        val whitespace = source.copy(title = " ", blocks = listOf(
            source.blocks.first().copy(spans = listOf(Span("text", " "))), body))
        val rows = readingRows(listOf(whitespace))
        assertTrue(initiallyFolded(rows.first(), AppSettings(collapseOtherSections = true)))
        assertEquals(listOf(rows.first()), visibleReadingRows(rows, setOf("heading-0")))
        assertEquals(listOf("heading-0"), foldedEntryTextSections(rows, setOf("heading-0")))
        assertEquals(rows, visibleReadingRows(rows, emptySet()))
        val legacyRows = readingRows(listOf(whitespace.copy(headingStyle = null)))
        assertFalse(initiallyFolded(legacyRows.first(), AppSettings(collapseOtherSections = true)))
        assertEquals(legacyRows, visibleReadingRows(legacyRows, setOf("heading-0")))
    }
}
