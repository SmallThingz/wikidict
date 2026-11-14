package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Pure source lowering controls; no producer or rendered-edition qualification. */
class AuthoredInlineTextLoweringTest {
    private fun height(value: Float) = InlineTextStyle(lineHeight =
        InlineLineHeight.Computed(InlineComputedLength(value, FontScaleBasis.CssPx)))
    private fun owner(value: Float = 30f, direction: String = "rtl") =
        Span("text", "", superscript = true, direction = direction, inlineStyle = height(value))

    @Test fun sevenEmptyOwnersRemainDistinctAtOneOffsetWithoutLogicalCharacters() {
        val owners = (1..7).map { owner(it * 10f) }
        val block = Block("paragraph", 0, owners)
        assertSame(owners, compactSpans(owners))
        val display = paragraphDisplaySpans(block)
        assertEquals(7, display.size)
        owners.zip(display).forEach { (expected, actual) -> assertSame(expected, actual) }
        assertTrue(paragraphHasContent(block))
        assertTrue(display.all { it.isEmptyInlineMetricOwner() && !it.usesInlineDirectionIsolate() })
        assertEquals(0, display.nativeLogicalLength())
        assertEquals("", display.joinToString("") { it.text + it.trail })
        assertTrue(nativeCaptionLinkRanges(display).isEmpty())
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val styledBlock = block.copy(style = BlockStyle(padding = StyleEdges(zero, zero, zero, zero)))
        val styledDisplay = paragraphDisplaySpans(styledBlock)
        assertEquals(owners, styledDisplay)
        owners.zip(styledDisplay).forEach { (expected, actual) -> assertSame(expected, actual) }
        assertEquals(0, styledDisplay.nativeLogicalLength())
        assertTrue(nativeCaptionLinkRanges(styledDisplay).isEmpty())
        assertTrue(paragraphHasContent(styledBlock))
    }

    @Test fun zeroOwnersSurviveBreakCompactionWhileLegacyEmptyContentIsStillDropped() {
        val metric = owner()
        val ordinary = Span("text", "", superscript = true, direction = "rtl")
        val breakSpan = Span("line_break", "")
        val source = listOf(ordinary, Span("text", "before"), breakSpan, metric, ordinary, breakSpan, Span("text", "after"))
        val display = compactSpans(source)
        assertEquals(listOf(Span("text", "before"), breakSpan, metric, ordinary, breakSpan, Span("text", "after")), display)
        assertFalse(paragraphHasContent(Block("paragraph", 0, listOf(ordinary))))
        assertTrue(compactSpans(listOf(ordinary)).isEmpty())
        assertTrue(ordinary.usesInlineDirectionIsolate()) // The old owner has its unchanged legacy policy.
        assertFalse(metric.copy(trail = "x").isEmptyInlineMetricOwner())
        assertTrue(metric.copy(trail = "x").usesInlineDirectionIsolate())
    }

    @Test fun collapsedAsciiMetricSpanKeepsItsFontOwnerAndNextActionOffsets() {
        val metric = owner().copy(text = "\t ", language = "th", bold = true)
        val link = Span("link", "go", target = "target", direction = "ltr")
        val raw = listOf(Span("text", "a "), metric, link)
        val display = ordinaryInlineDisplaySpans(Block("paragraph", 0, raw))
        assertEquals(metric.copy(text = ""), display[1])
        assertTrue(display[1].isEmptyInlineMetricOwner())
        assertEquals("\t ", metric.text)
        assertEquals(6, display.nativeLogicalLength())
        val action = nativeCaptionLinkRanges(display).single()
        assertEquals(2, action.index)
        assertEquals(2, action.start)
        assertEquals(6, action.end)
        assertSame(link, action.span)
    }

    @Test fun whitespaceOnlyStyledActionStaysOriginalForExplicitNativeRefusal() {
        val action = Span("link", " \t", target = "retained-target", inlineStyle = height(20f))
        val source = listOf(Span("text", "before "), action, Span("text", "after"))
        val display = ordinaryInlineDisplaySpans(Block("paragraph", 0, source))
        assertSame(action, display[1])
        assertTrue(action.isUnsupportedAuthoredWhitespaceOwner())
        assertSame(action, paragraphDisplaySpans(Block("paragraph", 0, listOf(action))).single())
        assertFalse(action.copy(text = "visible").isUnsupportedAuthoredWhitespaceOwner())
        assertFalse(action.copy(inlineStyle = null).isUnsupportedAuthoredWhitespaceOwner())
        assertFalse(owner().isUnsupportedAuthoredWhitespaceOwner())
        assertFalse(action.copy(text = "\u00a0").isUnsupportedAuthoredWhitespaceOwner())
        for (cursorStyle in listOf(InlineTextStyle(cursor = InlineCursor.Help),
            height(20f).copy(cursor = InlineCursor.Help))) {
            val cursor = Span("text", " \t", inlineStyle = cursorStyle)
            val block = Block("paragraph", 0, listOf(Span("text", "before "), cursor, Span("text", "after")))
            assertTrue(cursor.isUnsupportedAuthoredWhitespaceOwner())
            assertSame(cursor, ordinaryInlineDisplaySpans(block)[1])
            assertSame(cursor, paragraphDisplaySpans(Block("paragraph", 0, listOf(cursor))).single())
        }
        for (noncollapsibleStyle in listOf(InlineTextStyle(cursor = InlineCursor.Help),
            InlineTextStyle(decoration = InlineUnderline(InlineUnderlineStyle.Dotted)))) {
            val nonbreaking = Span("text", "\u00a0", inlineStyle = noncollapsibleStyle)
            assertFalse(nonbreaking.isUnsupportedAuthoredWhitespaceOwner())
            assertSame(nonbreaking, compactSpans(listOf(nonbreaking)).single())
            assertSame(nonbreaking, paragraphDisplaySpans(Block("paragraph", 0, listOf(nonbreaking))).single())
            assertTrue(paragraphHasContent(Block("paragraph", 0, listOf(nonbreaking))))
            assertEquals(1, listOf(nonbreaking).nativeLogicalLength())
        }
        for (trail in listOf("!", "\u00a0")) {
            for (effect in listOf(height(20f).copy(cursor = InlineCursor.Help),
                InlineTextStyle(decoration = InlineUnderline(InlineUnderlineStyle.Dotted)))) {
                val original = Span("text", " \t", trail = trail, inlineStyle = effect)
                val block = Block("paragraph", 0, listOf(Span("text", "prefix "), original, Span("text", "after")))
                assertTrue(original.isUnsupportedAuthoredWhitespaceOwner())
                assertSame(original, ordinaryInlineDisplaySpans(block)[1])
            }
            val originalAction = action.copy(trail = trail)
            assertTrue(originalAction.isUnsupportedAuthoredWhitespaceOwner())
            assertSame(originalAction, ordinaryInlineDisplaySpans(Block("paragraph", 0,
                listOf(Span("text", "prefix "), originalAction)))[1])
        }
    }

    @Test fun snapshotProbeOwnsTheCompleteFontTupleAndExplicitFalseDefaults() {
        val snapshot = InlineFontSnapshot(fontScale = 22f, fontScaleBasis = FontScaleBasis.CssPx,
            small = true, superscript = true, fontNormalized = true, bold = true, italic = true,
            code = true, language = "th", classes = "IPA", role = "pronunciation",
            fontFeatures = FontFeaturePolicy.SevenOn)
        val probe = inlineFontSnapshotSpan(snapshot)
        assertTrue(snapshot.matches(probe, true))
        assertEquals("text", probe.kind)
        assertEquals(" ", probe.text)
        assertEquals("", probe.target)
        assertEquals("", probe.direction)
        assertNull(probe.inlineStyle?.lineHeight)
        assertNull(probe.inlineStyle?.decoration)
        assertNull(probe.inlineStyle?.baselineShift)
        val reset = inlineFontSnapshotSpan(InlineFontSnapshot())
        assertFalse(reset.small || reset.superscript || reset.subscript || reset.bold || reset.italic || reset.code)
        assertEquals("", reset.language)
        assertEquals("", reset.classes)
        assertEquals("normal", reset.role)
        assertNull(reset.fontScale)
        assertNull(reset.fontFeatures)
        assertNull(reset.inlineStyle)
    }

    @Test fun actualOwnerProbePreservesFontSemanticsButDoesNotCarryAnActionOrInlineEffect() {
        val span = Span("link", "source", target = "target", targetFragment = "fragment", trail = "!",
            direction = "rtl", language = "th", classes = "IPA", role = "pronunciation", bold = true,
            italic = true, small = true, superscript = true, underline = true, strike = true,
            fontScale = 1.5f, fontScaleBasis = FontScaleBasis.NormalBody,
            fontFeatures = FontFeaturePolicy.Normal,
            inlineStyle = InlineTextStyle(decoration = InlineUnderline(InlineUnderlineStyle.Dotted, "#112233"),
                lineHeight = InlineLineHeight.Computed(InlineComputedLength(0f, FontScaleBasis.CssPx)),
                baselineShift = InlineComputedLength(-2f, FontScaleBasis.CssPx), fontNormalized = true))
        val probe = inlineMetricOwnerSpan(span)
        assertEquals("text", probe.kind)
        assertEquals(" ", probe.text)
        assertEquals("", probe.target)
        assertNull(probe.targetFragment)
        assertEquals("", probe.trail)
        assertEquals("", probe.direction)
        assertFalse(probe.underline || probe.strike)
        assertEquals(InlineTextStyle(fontNormalized = true), probe.inlineStyle)
        assertTrue(probe.bold && probe.italic && probe.small && probe.superscript)
        assertEquals(span.language, probe.language)
        assertEquals(span.classes, probe.classes)
        assertEquals(span.role, probe.role)
        assertEquals(span.fontScale, probe.fontScale)
        assertEquals(span.fontScaleBasis, probe.fontScaleBasis)
        assertEquals(span.fontFeatures, probe.fontFeatures)
        assertEquals("source", span.text)
        assertEquals("target", span.target)
    }

    @Test fun tableShortcutDetectionVisitsRichCaptionsOrderedCellsAndNestedTables() {
        val ordinary = Span("text", "ordinary")
        val metric = owner()
        fun table(spans: List<Span>) = Table(emptyList(), listOf(listOf(Cell(spans, false, 1, 1))))
        assertFalse(tableHasAuthoredInlineStyles(table(listOf(ordinary))))
        assertTrue(tableHasAuthoredInlineStyles(table(listOf(metric))))
        assertTrue(tableHasAuthoredInlineStyles(Table(listOf(metric), emptyList())))
        assertTrue(tableHasAuthoredInlineStyles(Table(emptyList(), emptyList(), captionBlocks =
            listOf(Block("paragraph", 0, listOf(metric))))))
        val nested = table(listOf(metric))
        assertTrue(tableHasAuthoredInlineStyles(Table(emptyList(), listOf(listOf(
            Cell(emptyList(), false, 1, 1, nestedTable = nested))))))
        assertTrue(tableHasAuthoredInlineStyles(Table(emptyList(), listOf(listOf(
            Cell(emptyList(), false, 1, 1, blocks = listOf(Block("paragraph", 0, listOf(metric)))))))))
    }

    @Test fun denseParagraphKeepsItsOriginalBreakAndZeroOwnerInsteadOfSplittingAwayTheLine() {
        val point = owner()
        val spans = listOf(point, Span("line_break", "")) + (1..80).flatMap {
            listOf(Span("text", "word$it"), Span("line_break", ""))
        } + Span("text", "tail")
        val original = Block("paragraph", 0, spans)
        val rows = readingRows(listOf(Section(2, "", listOf(original)))).mapNotNull { it.block }
        assertEquals(1, rows.size)
        assertEquals(spans, rows.single().spans)
        assertSame(point, rows.single().spans.first())
        val legacy = original.copy(spans = spans.drop(2))
        assertTrue(readingRows(listOf(Section(2, "", listOf(legacy)))).mapNotNull { it.block }.size > 1)
        assertEquals(listOf(AnonymousInlineTextPart(0, 2, "go")),
            anonymousInlineSemantic(listOf(point, Span("text", "go")), "go"))
    }
}
