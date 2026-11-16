package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class RubyReadingLayoutTest {
    private val owner = RubyOwner(InlineFontSnapshot(fontScale = 1f))
    private fun ruby(base: List<Span>, reading: List<Span> = emptyList()): Span = Span("text", "", ruby = Ruby(listOf(
        RubySegment(emptyList(), listOf(RubyBase(owner, emptyList(), base)), listOf(
            RubyAnnotation(0, 1, 0, owner, emptyList(), reading, emptyList(), emptyList(), false))))))

    @Test fun whitespaceAndDenseRowsKeepOneOriginalTypedOwnerAndAllNeighbours() {
        val source = listOf(Span("text", "a "), ruby(listOf(Span("text", "B"))), Span("text", " c"))
        val block = Block("paragraph", 0, source)
        assertSame(source, compactSpans(source))
        assertSame(source, ordinaryInlineDisplaySpans(block))
        assertSame(source, paragraphDisplaySpans(block))
        assertEquals("a B c", rubyGraphicalText(paragraphDisplaySpans(block)))
        val dense = block.copy(spans = source + List(90) { Span("line_break", "") })
        val rows = readingRows(listOf(Section(2, "section", listOf(dense)))).filter { it.block != null }
        assertEquals(1, rows.size)
        assertSame(dense, rows.single().block)
        val ordinary = listOf(Span("text", " "), Span("text", "kept"), Span("text", " "))
        assertEquals(listOf(ordinary[1]), compactSpans(ordinary))
    }

    @Test fun emptyTypedOwnersSurviveContentAdmissionWithoutBecomingMetricProbeCharacters() {
        val empty = ruby(emptyList())
        val source = listOf(empty)
        assertTrue(source.hasCompiledInlineContent())
        assertTrue(paragraphHasContent(Block("paragraph", 0, source)))
        assertSame(source, compactSpans(source))
        assertEquals(0, source.nativeLogicalLength())
        assertEquals("", rubyGraphicalText(source))
        val metric = empty.copy(inlineStyle = InlineTextStyle(lineHeight = InlineLineHeight.Computed(
            InlineComputedLength(12f, FontScaleBasis.CssPx))))
        assertFalse(metric.isEmptyInlineMetricOwner())
        assertFalse(metric.isUnsupportedAuthoredWhitespaceOwner())
        assertNull(inlineMetricOwnerSpan(metric).ruby)
        assertEquals(" ", inlineMetricOwnerSpan(metric).text)
        assertFalse(paragraphHasContent(Block("paragraph", 0, emptyList())))
    }

    @Test fun graphicalUtf16AndEgyptianRangesExcludeHiddenReadingAndSyntheticIsolates() {
        val sign = "\ud80c\udc00"
        val base = Span("link", "A\ud83d\ude80", "base", trail = "\u0301", direction = "rtl")
        val hidden = Span("link", base.text, "hidden", trail = base.trail)
        val source = listOf(Span("text", "x", direction = "rtl"), ruby(listOf(base), listOf(hidden)),
            Span("text", sign, classes = "Egyp", direction = "ltr"))
        assertEquals("xA\ud83d\ude80\u0301$sign", rubyGraphicalText(source))
        assertEquals(7, source.nativeLogicalLength())
        val run = egyptianTextRuns(source).single()
        assertEquals(5, run.start)
        assertEquals(7, run.end)
        assertTrue(run.reuseLtr)
        assertEquals(sign, run.text)
        val ordinary = listOf(Span("text", "x", direction = "rtl"), Span("text", sign, classes = "Egyp"))
        assertEquals(5, ordinary.nativeLogicalLength())
        assertEquals(3, egyptianTextRuns(ordinary).single().start)
    }

    @Test fun headingCompanionKeepsTerminalIdentityAndTypedGraphicalActions() {
        val child = Span("link", "base", "base-action")
        val reading = Span("link", "read", "reading-action")
        val source = listOf(ruby(listOf(child), listOf(reading)))
        val block = Block("heading", 2, source, level = 2)
        val section = Section(2, "base\uff08read\uff09", listOf(block))
        assertSame(block, sectionHeadingCompanion(section))
        assertEquals("baseread", rubyGraphicalText(source))
        assertEquals(listOf("base-action", "reading-action"), rubyGraphicalSpans(source).map { it.target })
        assertNull(sectionHeadingCompanion(section.copy(title = "baseread")))
    }

    @Test fun paddingOnlyOwnersKeepTheirSourceBoxWithoutAddingLogicalCharacters() {
        fun group(child: Span) = Span("text", "", inlinePaddingGroup = InlinePaddingGroup(
            StyleLength(StyleLengthUnit.Px, 0f), StyleLength(StyleLengthUnit.Em, .25f), listOf(child)))
        for (child in listOf(Span("text", ""), Span("text", "  "))) {
            val source = listOf(group(child))
            val block = Block("paragraph", 0, source)
            assertFalse(source.hasRuby())
            assertTrue(source.hasNativeInlineGroups())
            assertTrue(source.hasCompiledInlineContent())
            assertTrue(paragraphHasContent(block))
            assertSame(source, compactSpans(source))
            assertSame(source, ordinaryInlineDisplaySpans(block))
            assertSame(source, paragraphDisplaySpans(block))
            assertEquals(child.text, rubyGraphicalText(source))
            assertEquals(child.text.length, source.nativeLogicalLength())
            assertFalse(source.single().isEmptyInlineMetricOwner())
            assertFalse(source.single().isUnsupportedAuthoredWhitespaceOwner())
            val probe = inlineMetricOwnerSpan(source.single())
            assertNull(probe.inlinePaddingGroup)
            assertNull(probe.ruby)
            assertEquals(" ", probe.text)
            val dense = block.copy(spans = source + List(90) { Span("line_break", "") })
            val rows = readingRows(listOf(Section(2, "section", listOf(dense)))).filter { it.block != null }
            assertSame(dense, rows.single().block)
        }
        assertFalse(paragraphHasContent(Block("paragraph", 0, listOf(Span("text", "  ")))))
    }

    @Test fun paddingProjectionKeepsNestedRubyImageAltAndEgyptianUtf16Offsets() {
        val sign = "\ud80c\udc00"
        val grouped = Span("text", "", inlinePaddingGroup = InlinePaddingGroup(
            StyleLength(StyleLengthUnit.Em, .25f), StyleLength(StyleLengthUnit.Px, 3f), listOf(
                Span("text", "x"), ruby(listOf(Span("link", "B", "base")), listOf(Span("text", "r"))),
                Span("text", sign, classes = "Egyp"))))
        val image = Span("text", "", image = InlineImage("File:example.png", alt = "source alt"))
        val source = listOf(Span("text", "q"), grouped, image)
        val logical = "qxBr$sign\ufffc"
        assertEquals(logical, rubyGraphicalText(source))
        assertEquals(7, source.nativeLogicalLength())
        val parts = anonymousInlineSemantic(source, logical)
        assertEquals("qxBr${sign}source alt", parts.joinToString("") { it.text })
        assertEquals(listOf(0 to 1, 1 to 2, 2 to 3, 3 to 4, 4 to 6, 6 to 7),
            parts.map { it.start to it.end })
        assertTrue(parts.last().replacement)
        val run = egyptianTextRuns(source).single()
        assertEquals(4, run.start)
        assertEquals(6, run.end)
        assertEquals(sign, run.text)
    }

    @Test fun paddingHeadingCompanionKeepsOriginalOwnerAndTerminalLabel() {
        val child = Span("link", "reading", "original-target")
        val group = Span("text", "", fontScale = 1.35f, inlinePaddingGroup = InlinePaddingGroup(
            StyleLength(StyleLengthUnit.Px, 0f), StyleLength(StyleLengthUnit.Em, .25f), listOf(child)))
        val block = Block("heading", 2, listOf(group), level = 2)
        val section = Section(2, "reading", listOf(block))
        assertSame(block, sectionHeadingCompanion(section))
        assertEquals("reading", rubyGraphicalText(block.spans))
        assertSame(child, rubyGraphicalSpans(block.spans).single())
        assertNull(sectionHeadingCompanion(section.copy(title = " reading")))
    }

}
