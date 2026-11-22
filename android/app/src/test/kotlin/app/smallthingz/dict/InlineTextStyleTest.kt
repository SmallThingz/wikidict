package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Typed constructor controls; source-only until the selected consumer is compiled and run. */
class InlineTextStyleTest {
    private val shift = InlineComputedLength(-.125f, FontScaleBasis.NormalBody)
    private val font = InlineFontSnapshot(.75f, FontScaleBasis.NormalBody, small = true,
        superscript = true, fontNormalized = true, italic = true, language = "ja", classes = "Jpan",
        role = "reference", fontFeatures = FontFeaturePolicy.SevenOn)
    private fun run(snapshot: InlineFontSnapshot = font, baseline: InlineComputedLength? = shift): Span =
        Span("text", "owner", fontScale = font.fontScale, fontScaleBasis = font.fontScaleBasis,
            small = font.small, superscript = font.superscript, subscript = font.subscript,
            bold = font.bold, italic = font.italic, code = font.code, language = font.language,
            classes = font.classes, role = font.role, fontFeatures = font.fontFeatures,
            inlineStyle = InlineTextStyle(lineHeight = InlineLineHeight.FontRelative(1f, snapshot),
                baselineShift = baseline, fontNormalized = font.fontNormalized))
    private fun rejects(label: String, action: () -> Any?) = assertTrue(label, runCatching(action).isFailure)

    @Test fun effectsRemainIndependentFromAnnotationsAndEightStateLinkPaint() {
        val state = LinkState("#123456", false)
        val paint = LinkPaint(state, state, state, state, state, state, state, state, false)
        val underline = InlineUnderline(InlineUnderlineStyle.Dotted, "#abcdef", StyleLength(StyleLengthUnit.Em, .125f))
        val span = Span("link", "abbr", "Target", targetFragment = "part", tooltip = "tooltip",
            explanation = "explanation", foreground = "#123456", linkPaint = paint,
            inlineStyle = InlineTextStyle(decoration = underline))
        assertEquals(EntryLink("Target", "part"), span.entryLink())
        assertEquals("tooltip", span.tooltip); assertEquals("explanation", span.explanation)
        assertEquals(underline, span.inlineStyle!!.decoration)
        assertFalse(span.linkPaint!!.state(false, true, true).underline)
        assertEquals(InlineUnderline(InlineUnderlineStyle.Solid),
            span.copy(inlineStyle = InlineTextStyle(decoration = InlineUnderline(InlineUnderlineStyle.Solid))).inlineStyle!!.decoration)
        assertEquals(shift, Span("text", "x", inlineStyle = InlineTextStyle(baselineShift = shift)).inlineStyle!!.baselineShift)
        assertNotNull(Span("external_link", "source", "https://example.test/", inlineStyle = span.inlineStyle).inlineStyle)
        assertNull(Span("text", "plain").inlineStyle)
    }

    @Test fun typedDomainsRejectEmptyPoliciesInvalidNumbersBasesColorsAndSnapshots() {
        rejects("empty effects") { InlineTextStyle() }
        for (bad in listOf(Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            rejects("computed $bad") { InlineComputedLength(bad, FontScaleBasis.CssPx) }
            rejects("factor $bad") { InlineLineHeight.FontRelative(bad, InlineFontSnapshot()) }
            rejects("scale $bad") { InlineFontSnapshot(fontScale = bad) }
        }
        rejects("negative factor") { InlineLineHeight.FontRelative(-.01f, InlineFontSnapshot()) }
        rejects("negative scale") { InlineFontSnapshot(fontScale = -.01f) }
        rejects("computed context") { InlineComputedLength(1f, FontScaleBasis.Context) }
        rejects("negative height") { InlineLineHeight.Computed(shift) }
        for (basis in listOf(FontScaleBasis.NormalBody, FontScaleBasis.CssPx)) {
            assertEquals(0f, InlineLineHeight.Computed(InlineComputedLength(0f, basis)).value.value, 0f)
            assertEquals(-1f, InlineComputedLength(-1f, basis).value, 0f)
            rejects("absent scale $basis") { InlineFontSnapshot(fontScaleBasis = basis) }
        }
        rejects("normalized context") { InlineFontSnapshot(1f, fontNormalized = true) }
        for (bad in listOf("#ABCDEF", "#abc", "red", "#12345678"))
            rejects("RGB $bad") { InlineUnderline(InlineUnderlineStyle.Solid, bad) }
        rejects("negative thickness") { InlineUnderline(InlineUnderlineStyle.Dotted, thickness = StyleLength(StyleLengthUnit.Px, -1f)) }
        for (bad in listOf("bad\u0000tag", "\ud800", "\udc00")) {
            rejects("language") { font.copy(language = bad) }
            rejects("classes") { font.copy(classes = bad) }
        }
        rejects("role") { font.copy(role = "unknown") }
        assertEquals("x-private", font.copy(language = "x-private").language)
        assertEquals("\ud83d\ude00", font.copy(classes = "\ud83d\ude00").classes)
        // Keep the earlier table type's positive/context-or-body domain unchanged.
        rejects("legacy table zero") { ComputedLineHeight(0f) }
        rejects("legacy table CSS px") { ComputedLineHeight(1f, FontScaleBasis.CssPx) }
        assertEquals(FontScaleBasis.Context, ComputedLineHeight(1f).fontScaleBasis)
    }

    @Test fun presentEffectsRequireTheActualSpanOwnerWithoutNarrowingLegacySpans() {
        val decoration = InlineTextStyle(decoration = InlineUnderline(InlineUnderlineStyle.Solid))
        for (kind in listOf("line_break", "unknown"))
            rejects(kind) { Span(kind, "x", inlineStyle = decoration) }
        rejects("text target") { Span("text", "x", "Target", inlineStyle = decoration) }
        for (kind in listOf("link", "external_link")) {
            rejects("missing target") { Span(kind, "x", inlineStyle = decoration) }
            rejects("empty link") { Span(kind, "", "Target", inlineStyle = decoration) }
        }
        rejects("image") { Span("text", "", image = InlineImage("Owned.svg"), inlineStyle = decoration) }
        rejects("empty decoration") { Span("text", "", inlineStyle = decoration) }
        rejects("empty shift") { Span("text", "", inlineStyle = InlineTextStyle(baselineShift = shift)) }
        rejects("missing normalized scale") { Span("text", "x", inlineStyle = InlineTextStyle(fontNormalized = true)) }
        rejects("normalized context") { Span("text", "x", fontScale = 1f, inlineStyle = InlineTextStyle(fontNormalized = true)) }
        rejects("nonfinite owner") { Span("text", "x", fontScale = Float.NaN, inlineStyle = decoration) }
        assertNull(Span("line_break", "").inlineStyle)
        assertNull(Span("link", "", "Target").inlineStyle)
        assertNull(Span("text", "", image = InlineImage("Owned.svg")).inlineStyle)
    }

    @Test fun shiftedFontRelativeOwnerRequiresEveryExactFontFieldWhileUnshiftedOwnerMayDiffer() {
        assertEquals(font, (run().inlineStyle!!.lineHeight as InlineLineHeight.FontRelative).font)
        val variants = listOf(font.copy(fontScale = .5f), font.copy(fontScaleBasis = FontScaleBasis.CssPx),
            font.copy(small = false), font.copy(superscript = false), font.copy(subscript = true),
            font.copy(fontNormalized = false), font.copy(bold = true), font.copy(italic = false),
            font.copy(code = true), font.copy(language = "de"), font.copy(classes = ""),
            font.copy(role = "normal"), font.copy(fontFeatures = null), font.copy(fontFeatures = FontFeaturePolicy.Normal))
        for (variant in variants) {
            rejects("different snapshot $variant") { run(variant) }
            assertEquals(variant, (run(variant, null).inlineStyle!!.lineHeight as InlineLineHeight.FontRelative).font)
        }
        val context = InlineFontSnapshot(1f)
        val policy = InlineTextStyle(lineHeight = InlineLineHeight.FontRelative(1f, context), baselineShift = shift)
        assertEquals(1f, Span("text", "x", fontScale = 1f, inlineStyle = policy).fontScale!!, 0f)
        rejects("explicit context one is not absent") { Span("text", "x", inlineStyle = policy) }
        val zero = policy.copy(lineHeight = InlineLineHeight.FontRelative(0f, InlineFontSnapshot(-0f)))
        assertNotNull(Span("text", "x", fontScale = 0f, inlineStyle = zero))
    }

    @Test fun distinctEmptyOwnersKeepTheirFontsAndExactBodyActionOffsets() {
        val first = Span("text", "", superscript = true, language = "th", classes = "owner-one",
            inlineStyle = InlineTextStyle(lineHeight = InlineLineHeight.FontRelative(1f, InlineFontSnapshot(superscript = true))))
        val second = Span("text", "", small = true, italic = true, role = "label", fontScale = .5f,
            inlineStyle = InlineTextStyle(lineHeight = InlineLineHeight.Computed(InlineComputedLength(0f, FontScaleBasis.CssPx))))
        val spans = listOf(Span("text", "ab"), first, second, Span("link", "cd", "Target", targetFragment = "part"))
        assertEquals("abcd", textOf(spans))
        assertEquals(4, spans.nativeLogicalLength())
        assertEquals(listOf(0, 2, 2, 2, 4), spans.runningFold(0) { offset, span -> offset + listOf(span).nativeLogicalLength() })
        assertNotEquals(first.inlineStyle, second.inlineStyle)
        val visited = mutableListOf<Span>()
        Block("paragraph", 0, spans).visitSpanRuns { source, _ -> visited += source }
        assertEquals(spans, visited)
        assertSame(first, visited[1]); assertSame(second, visited[2])
        assertEquals(EntryLink("Target", "part"), visited.last().entryLink())
    }

    @Test fun normalizedFontSuppressesOnlyLegacyScriptSizeAndKeepsSourceBasisZoomAndCaps() {
        val old = Span("text", "x", fontScale = .5f, fontScaleBasis = FontScaleBasis.NormalBody,
            small = true, superscript = true, subscript = true)
        val normalized = old.copy(inlineStyle = InlineTextStyle(fontNormalized = true))
        assertEquals(.4f, spanFontScale(old), .00001f)
        assertEquals(.5f, spanFontScale(normalized), 0f)
        assertEquals(8f, spanFontPixels(old, 100f, 20f), .00001f)
        assertEquals(10f, spanFontPixels(normalized, 100f, 20f), 0f)
        val pixels = old.copy(fontScale = 12.5f, fontScaleBasis = FontScaleBasis.CssPx)
        assertEquals(15f, cssPixelNominalFontSp(pixels, 1.5f), .00001f)
        assertEquals(18.75f, cssPixelNominalFontSp(pixels.copy(inlineStyle = normalized.inlineStyle), 1.5f), 0f)
        val decorated = old.copy(inlineStyle = InlineTextStyle(decoration = InlineUnderline(InlineUnderlineStyle.Solid)))
        assertEquals(spanFontPixels(old, 100f, 20f), spanFontPixels(decorated, 100f, 20f), 0f)
        assertEquals(MaxComputedFontPixels, spanFontPixels(normalized.copy(fontScale = Float.MAX_VALUE), 20f, 20f), 0f)
        assertEquals(0f, spanFontPixels(normalized.copy(fontScale = 0f), 20f, 20f), 0f)
        assertTrue(normalized.small && normalized.superscript && normalized.subscript)
        assertNull(normalized.inlineStyle!!.baselineShift)
    }

    @Test fun helpCursorRequiresNonemptySourceTextWithoutAddingAnActionOrMetricCharacter() {
        val help = InlineTextStyle(cursor = InlineCursor.Help)
        val text = Span("text", "BC", trail = " ", inlineStyle = help)
        assertEquals(InlineCursor.Help, text.inlineStyle!!.cursor)
        assertNull(help.decoration); assertNull(help.lineHeight); assertNull(help.baselineShift)
        assertFalse(help.fontNormalized); assertFalse(text.hasInternalAction())
        for (kind in listOf("link", "external_link")) {
            val action = Span(kind, "DE", "Target", inlineStyle = help)
            assertEquals(kind, action.kind); assertEquals("Target", action.target)
            assertEquals("DE", action.text); assertNull(action.linkPaint)
        }
        val strut = Span("text", "", inlineStyle = InlineTextStyle(lineHeight =
            InlineLineHeight.Computed(InlineComputedLength(0f, FontScaleBasis.NormalBody))))
        rejects("empty metric cursor owner") { strut.copy(inlineStyle = strut.inlineStyle!!.copy(cursor = InlineCursor.Help)) }
        rejects("empty cursor-only owner") { Span("text", "", inlineStyle = help) }
        rejects("line-break cursor owner") { Span("line_break", "", inlineStyle = help) }
        rejects("image cursor owner") { Span("text", "", image = InlineImage("Owned.svg"), inlineStyle = help) }
        rejects("cursor does not supply target") { Span("link", "action", inlineStyle = help) }
        rejects("cursor does not supply link text") { Span("external_link", "", "Target", inlineStyle = help) }
        val source = listOf(Span("text", "A"), text, strut, Span("link", "DE", "Target", inlineStyle = help))
        assertEquals("ABC DE", textOf(source)); assertEquals(6, source.nativeLogicalLength())
        assertEquals(listOf(0, 1, 4, 4, 6), source.runningFold(0) { n, span -> n + listOf(span).nativeLogicalLength() })
        assertNull(Span("text", "advice", explanation = "help", tooltip = "help").inlineStyle)
        assertNull(Span("link", "action", "Target", tooltip = "help").inlineStyle)
    }
}
