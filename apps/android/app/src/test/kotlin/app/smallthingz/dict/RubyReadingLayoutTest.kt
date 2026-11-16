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


    @Test fun actionOwnersRetainEmptyMetricContentAndOriginalNeighbours() {
        val metric = Span("text", "", inlineStyle = InlineTextStyle(lineHeight = InlineLineHeight.Computed(
            InlineComputedLength(12f, FontScaleBasis.CssPx))))
        for (child in listOf(Span("text", ""), metric, Span("text", "  "))) {
            val action = Span("link", "", "original", inlineActionGroup = InlineActionGroup(listOf(child)))
            val source = listOf(Span("text", " "), action, Span("text", " "))
            val block = Block("paragraph", 0, source)
            assertFalse(source.hasRuby())
            assertTrue(source.hasNativeInlineGroups())
            assertTrue(source.hasCompiledInlineContent())
            assertTrue(paragraphHasContent(block))
            assertSame(source, compactSpans(source))
            assertSame(source, ordinaryInlineDisplaySpans(block))
            assertSame(source, paragraphDisplaySpans(block))
            assertEquals(" ${child.text} ", rubyGraphicalText(source))
            assertEquals(child.text.length + 2, source.nativeLogicalLength())
            assertFalse(action.isEmptyInlineMetricOwner())
            assertFalse(action.isUnsupportedAuthoredWhitespaceOwner())
            val probe = inlineMetricOwnerSpan(action)
            assertNull(probe.inlineActionGroup)
            assertNull(probe.inlinePaddingGroup)
            assertNull(probe.ruby)
            assertEquals("text", probe.kind)
            assertEquals("", probe.target)
            assertEquals(" ", probe.text)
            assertSame(child, action.inlineActionGroup!!.spans.single())
            val dense = block.copy(spans = source + List(90) { Span("line_break", "") })
            val rows = readingRows(listOf(Section(2, "section", listOf(dense)))).filter { it.block != null }
            assertSame(dense, rows.single().block)
        }
        assertFalse(paragraphHasContent(Block("paragraph", 0, listOf(Span("text", "  ")))))
    }

    @Test fun actionProjectionKeepsNestedRubyPaddingImageAltAndEgyptianOffsets() {
        val sign = "\ud80c\udc00"
        val padding = Span("text", "", inlinePaddingGroup = InlinePaddingGroup(
            StyleLength(StyleLengthUnit.Em, .25f), StyleLength(StyleLengthUnit.Px, 1f),
            listOf(Span("text", sign, classes = "Egyp"))))
        val children = listOf(Span("text", "x"), ruby(listOf(Span("text", "B")), listOf(Span("text", "r"))), padding)
        val action = Span("link", "", "owner", inlineActionGroup = InlineActionGroup(children))
        val image = Span("text", "", image = InlineImage("File:example.png", alt = "source alt"))
        val source = listOf(Span("text", "q"), action, image)
        val logical = "qxBr$sign\ufffc"
        assertEquals(logical, rubyGraphicalText(source))
        assertEquals(7, source.nativeLogicalLength())
        val parts = anonymousInlineSemantic(source, logical)
        assertEquals("qxBr${sign}source alt", parts.joinToString("") { it.text })
        assertEquals(listOf(0 to 1, 1 to 2, 2 to 3, 3 to 4, 4 to 6, 6 to 7), parts.map { it.start to it.end })
        assertTrue(parts.last().replacement)
        val run = egyptianTextRuns(source).single()
        assertEquals(4, run.start)
        assertEquals(6, run.end)
        assertEquals(sign, run.text)
        assertSame(children, action.inlineActionGroup!!.spans)
        assertEquals(listOf("text", "text", "text"), children.map { it.kind })
    }

    @Test fun actionHeadingKeepsWholeSourceOwnersWithDistinctEqualTargets() {
        val firstChildren = listOf(Span("text", "d", italic = true), Span("text", "a", superscript = true))
        val first = Span("link", "", "same-target", inlineActionGroup = InlineActionGroup(firstChildren))
        val second = Span("link", "", "same-target", inlineActionGroup = InlineActionGroup(listOf(Span("text", "x"))))
        val source = listOf(first, second)
        val block = Block("heading", 2, source, level = 2)
        val section = Section(2, "dax", listOf(block))
        assertSame(block, sectionHeadingCompanion(section))
        assertEquals("dax", rubyGraphicalText(source))
        val owners = rubyGraphicalProjection(source).ranges.filter { it.role == RubyTextRole.ActionGroup }
        assertEquals(listOf(0 to 2, 2 to 3), owners.map { it.start to it.end })
        assertSame(first, owners[0].span)
        assertSame(second, owners[1].span)
        assertNotEquals(owners[0].path, owners[1].path)
        assertEquals(listOf("same-target", "same-target", "same-target"), rubyGraphicalSpans(source).map { it.target })
        assertSame(firstChildren, first.inlineActionGroup!!.spans)
        assertNull(sectionHeadingCompanion(section.copy(title = "d a x")))
    }


    @Test fun inlineBoxesKeepCompiledNeighboursDenseRowsAndMetricProbeBoundaries() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val none = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None,
            InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        for (body in listOf(" ", "\u00a0", "\u200d", "word")) {
            val child = Span("text", body)
            val group = Span("text", "", fontScale = 1.35f,
                inlineStyle = InlineTextStyle(lineHeight = InlineLineHeight.Computed(
                    InlineComputedLength(12f, FontScaleBasis.CssPx)), cursor = InlineCursor.Help),
                inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, zero, zero, zero), none, spans = listOf(child)))
            val source = listOf(Span("text", " "), group, Span("text", " "))
            val block = Block("paragraph", 0, source)
            assertTrue(source.hasNativeInlineGroups()); assertFalse(source.hasRuby())
            assertTrue(source.hasCompiledInlineContent()); assertTrue(paragraphHasContent(block))
            assertSame(source, compactSpans(source))
            assertSame(source, ordinaryInlineDisplaySpans(block)); assertSame(source, paragraphDisplaySpans(block))
            assertEquals(" $body ", rubyGraphicalText(source))
            assertEquals(body.length + 2, source.nativeLogicalLength())
            assertFalse(group.isEmptyInlineMetricOwner()); assertFalse(group.isUnsupportedAuthoredWhitespaceOwner())
            val probe = inlineMetricOwnerSpan(group)
            assertEquals(" ", probe.text); assertEquals("text", probe.kind); assertEquals("", probe.target)
            assertNull(probe.inlineBoxGroup); assertNull(probe.inlineActionGroup)
            assertNull(probe.inlinePaddingGroup); assertNull(probe.ruby)
            assertEquals(group.fontScale, probe.fontScale)
            assertSame(child, group.inlineBoxGroup!!.spans.single())
            val dense = block.copy(spans = source + List(90) { Span("line_break", "") })
            val rows = readingRows(listOf(Section(2, "section", listOf(dense)))).filter { it.block != null }
            assertEquals(1, rows.size); assertSame(dense, rows.single().block)
            if (body == "word") {
                val heading = Block("heading", 2, listOf(group), level = 2)
                assertSame(heading, sectionHeadingCompanion(Section(2, body, listOf(heading))))
            }
        }
        val ordinary = listOf(Span("text", " "), Span("text", "kept"), Span("text", " "))
        assertEquals(listOf(ordinary[1]), compactSpans(ordinary))
    }

    @Test fun inlineBoxCopyAndEgyptianRangesContainOnlyOriginalChildUtf16() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val none = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None,
            InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        val sign = "\ud80c\udc00"
        val marked = Span("text", "\ud83d\ude80", trail = "\u0301")
        val baseAction = Span("link", "B", "base-target")
        val children = listOf(Span("text", "x"), marked,
            ruby(listOf(baseAction), listOf(Span("text", "r"))), Span("text", sign, classes = "Egyp"))
        val overlay = InlineBoxOverlay(InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Percent, 50f),
            right = InlineBoxInset(StyleWidthUnit.Em, -.125f)), none.copy(left =
                InlineBoxBorderEdge.Dotted(StyleLength(StyleLengthUnit.Px, .75f), InlineBoxColor.CurrentColor)))
        val box = Span("text", "", direction = "rtl", inlineBoxGroup = InlineBoxGroup(
            StyleEdges(zero, StyleLength(StyleLengthUnit.Em, .25f), zero, zero), none,
            overlays = listOf(overlay, overlay), spans = children))
        val br = Span("line_break", "")
        val image = Span("text", "", image = InlineImage("File:example.png", alt = "source alt"))
        val source = listOf(Span("text", "q"), box, br, image)
        val logical = "qx\ud83d\ude80\u0301Br${sign}\n\ufffc"
        assertEquals(logical, rubyGraphicalText(source)); assertEquals(11, source.nativeLogicalLength())
        val projection = rubyGraphicalProjection(source)
        val ownerRange = projection.ranges.single { it.role == RubyTextRole.BoxGroup }
        assertSame(box, ownerRange.span); assertEquals(1, ownerRange.start); assertEquals(9, ownerRange.end)
        val parts = anonymousInlineSemantic(source, logical)
        assertEquals("qx\ud83d\ude80\u0301Br${sign}\nsource alt", parts.joinToString("") { it.text })
        assertEquals(listOf(0 to 1, 1 to 2, 2 to 5, 5 to 6, 6 to 7, 7 to 9, 9 to 10, 10 to 11),
            parts.map { it.start to it.end })
        assertTrue(parts.last().replacement)
        val run = egyptianTextRuns(source).single()
        assertEquals(7, run.start); assertEquals(9, run.end); assertEquals(sign, run.text)
        assertSame(marked, projection.ranges.single { it.span === marked }.span)
        assertSame(children, box.inlineBoxGroup!!.spans)
        assertSame(overlay, box.inlineBoxGroup!!.overlays[0]); assertSame(overlay, box.inlineBoxGroup!!.overlays[1])
        assertEquals(listOf(baseAction), projection.ranges.mapNotNull { it.span }.filter { it.hasInternalAction() })
        assertSame(baseAction, rubyGraphicalSpans(source).single { it.hasInternalAction() })
        assertSame(br, rubyFallbackSpans(source).single { it.kind == "line_break" })
        assertEquals("\u0301", marked.trail); assertEquals("text", marked.kind)
    }

    @Test fun inlineBoxesRetainTableCellBodiesWhileUnprovedHeightIntrinsicsRefuse() {
        val first = Span("text", "lead ", bold = true)
        val action = Span("link", "B\ud83d\ude80", "boxed-cell-target", trail = "\u00a0",
            italic = true, fontScale = 1.35f)
        val children = listOf(first, action)
        val ordinary = Cell(children, false, 1, 1)
        val paragraph = Block("paragraph", 0, children, textAlign = CellTextAlign.Center)
        val centered = Cell(emptyList(), false, 1, 1, blocks = listOf(paragraph))
        assertTrue(pairedTableCellHasIntrinsicHeight(ordinary))
        assertSame(paragraph, intrinsicTableSingleParagraph(centered))

        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val none = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None,
            InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        val box = Span("text", "", fontScale = 1.35f, inlineBoxGroup = InlineBoxGroup(
            StyleEdges(zero, StyleLength(StyleLengthUnit.Em, .25f), zero, zero), none, spans = children))
        val boxed = ordinary.copy(spans = listOf(box))
        val boxedParagraph = paragraph.copy(spans = listOf(box))
        val boxedCentered = centered.copy(blocks = listOf(boxedParagraph))
        // These helpers certify the existing synchronous cell-height path, not all valid text.
        assertFalse(pairedTableCellHasIntrinsicHeight(boxed))
        assertNull(intrinsicTableSingleParagraph(boxedCentered))
        assertSame(box, boxed.spans.single())
        assertSame(boxedParagraph, boxedCentered.blocks!!.single())
        assertSame(box, boxedParagraph.spans.single())
        assertSame(children, box.inlineBoxGroup!!.spans)
        assertSame(first, box.inlineBoxGroup!!.spans[0]); assertSame(action, box.inlineBoxGroup!!.spans[1])
        val expected = "lead B\ud83d\ude80\u00a0"
        assertEquals(expected, rubyGraphicalText(boxed.spans))
        assertEquals(expected, rubyGraphicalText(boxedParagraph.spans))
        assertEquals(expected, rubyFallbackText(boxed.spans))
        val originalAction = rubyGraphicalProjection(boxed.spans).ranges.mapNotNull { it.span }
            .single { it.hasInternalAction() }
        assertSame(action, originalAction)
        assertEquals("boxed-cell-target", originalAction.target)
        assertSame(action, rubyFallbackSpans(boxed.spans).single { it.hasInternalAction() })
        assertSame(children, ordinary.spans); assertSame(children, paragraph.spans)
        assertTrue(pairedTableCellHasIntrinsicHeight(ordinary))
        assertSame(paragraph, intrinsicTableSingleParagraph(centered))
    }
}
