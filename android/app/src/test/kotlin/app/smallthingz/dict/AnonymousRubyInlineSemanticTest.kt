package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Exact source/offset controls only; native Ruby shaping and actions are separately unrun. */
class AnonymousRubyInlineSemanticTest {
    private val context = RubyOwner(InlineFontSnapshot(), direction = "auto")
    private fun text(value: String) = Span("text", value)
    private fun base(spans: List<Span>, gap: List<Span> = emptyList()) = RubyBase(context, gap, spans)
    private fun reading(start: Long, spans: List<Span>, level: Long = 0,
        gap: List<Span> = emptyList(), before: List<Span> = emptyList(),
        after: List<Span> = emptyList(), explicit: Boolean = false) =
        RubyAnnotation(start, 1, level, context, gap, spans, before, after, explicit)
    private fun ruby(bases: List<RubyBase>, readings: List<RubyAnnotation>) =
        Span("text", "", ruby = Ruby(listOf(RubySegment(emptyList(), bases, readings))))

    @Test fun noRubyStillRemovesOnlyDeclaredIsolatesAndKeepsImageAltParts() {
        val spans = listOf(text("lit\u2066"),
            Span("link", "\u05d0\u05d1", "target", direction = "rtl", trail = "!"),
            Span("text", "", image = InlineImage("Image.png", alt = "image-alt")), text("."))
        val native = "lit\u2066\u2067\u05d0\u05d1!\u2069\ufffc."
        assertEquals(listOf(
            AnonymousInlineTextPart(0, 4, "lit\u2066"),
            AnonymousInlineTextPart(5, 7, "\u05d0\u05d1"),
            AnonymousInlineTextPart(7, 8, "!"),
            AnonymousInlineTextPart(9, 10, "image-alt", replacement = true),
            AnonymousInlineTextPart(10, 11, ".")), anonymousInlineSemantic(spans, native))
        assertThrows(IllegalStateException::class.java) { anonymousInlineSemantic(spans, native + "drift") }
    }

    @Test fun aggregateScopePreservesVisibleRubyLeavesAndExactUtf16ActionRanges() {
        val baseLink = Span("link", "A\ud83d\ude80", "base-target", trail = "\u0301", direction = "rtl")
        val firstReading = Span("link", "read", "reading-one", trail = "!", direction = "ltr")
        val secondReading = Span("link", "read", "reading-two", trail = "!", targetFragment = "", direction = "rtl")
        val hidden = Span("link", baseLink.text + baseLink.trail, "hidden-reading")
        val fallback = Span("link", "[", "fallback-only")
        val nested = ruby(listOf(base(listOf(text("N")))), listOf(reading(0, listOf(text("en")))))
        val owner = ruby(listOf(base(listOf(baseLink)),
            base(listOf(text("B"), nested), listOf(text("\t\n\r\u000c ")))), listOf(
            reading(0, listOf(firstReading), before = listOf(fallback), after = listOf(text("]")), explicit = true),
            reading(1, listOf(secondReading), gap = listOf(text(" "))),
            reading(0, listOf(hidden), level = 1)))
        val spans = listOf(Span("text", "pre\u2066", direction = "rtl"), owner,
            Span("text", "\u2069post", direction = "auto"))
        val expected = "pre\u2066A\ud83d\ude80\u0301\t\n\r\u000c BNenread! read!\u2069post"
        val projected = rubyGraphicalProjection(spans)
        assertEquals(expected, projected.text)
        val parts = anonymousInlineSemantic(spans, expected)
        assertEquals(expected, parts.joinToString("") { it.text })
        assertTrue(parts.none { it.replacement })
        assertTrue(parts.zipWithNext().all { (a, b) -> a.end == b.start })
        assertEquals(0, parts.first().start)
        assertEquals(expected.length, parts.last().end)
        val visible = projected.ranges.filter { it.span != null && it.role != RubyTextRole.Owner && it.start < it.end }
        assertEquals(visible.map { it.start to it.end }, parts.map { it.start to it.end })
        assertFalse(projected.ranges.any { it.span === hidden || it.span === fallback })
        val actions = visible.filter { it.span!!.kind == "link" }
        assertEquals(listOf(baseLink, firstReading, secondReading), actions.map { it.span })
        assertSame(baseLink, actions.first().span)
        assertEquals(4, actions.first().end - actions.first().start)
        assertNotEquals(actions[1].path, actions[2].path)

        val scope = BidiScope(BidiMode.Isolate, BidiDirectionInput.Rtl, BidiResolvedDirection.Rtl,
            "he", listOf(FlowPart.Inline(spans)))
        val content = anonymousFlowContent(Block("paragraph", 0, emptyList(), flow = listOf(FlowPart.Scope(scope))),
            AnonymousFlowContext(BidiResolvedDirection.Ltr, "en", null))
        val offsets = AnonymousFlowOffsets.build(content,
            { event, source -> anonymousInlineSemantic(event.layoutSpans, source) }) { event ->
            rubyGraphicalText(event.layoutSpans)
        }
        assertEquals("\u2067$expected\u2069", offsets.nativeText)
        assertEquals(expected, offsets.logicalText)
        val selection = AnonymousFlowSelection.build(offsets) { error("No figure in this control") }
        assertEquals(expected, selection.text)
        val source = offsets.inlineSources.single()
        assertEquals(1, source.start)
        for (offset in 0..expected.length)
            assertEquals(offset, selection.semanticOffset(selection.nativeOffset(offset)))
        actions.forEach { range ->
            val child = checkNotNull(range.span)
            val start = selection.semanticOffset(source.start + range.start)
            val end = selection.semanticOffset(source.start + range.end)
            assertEquals(range.start, start)
            assertEquals(range.end, end)
            assertEquals(child.text + child.trail, selection.text.substring(start, end))
        }
        assertThrows(IllegalStateException::class.java) {
            anonymousInlineSemantic(spans, "\u2067$expected\u2069")
        }
        assertThrows(IllegalStateException::class.java) {
            anonymousInlineSemantic(spans, expected + hidden.text)
        }
    }

    @Test fun ordinaryImageSiblingKeepsAltMappingAndEmptyRubyAddsNoSentinel() {
        val owner = ruby(listOf(base(listOf(text("A")))), listOf(reading(0, listOf(text("B")))))
        for (alt in listOf(null, "", "ALT")) {
            val link = Span("link", "Z", "after-image", targetFragment = "anchor", direction = "ltr")
            val spans = listOf(owner,
                Span("text", "", image = InlineImage("Image.png", alt = alt), direction = "rtl"), text("!"), link)
            val native = "AB\ufffc!Z"
            assertEquals(native, rubyGraphicalText(spans))
            val content = anonymousFlowContent(Block("paragraph", 0, spans),
                AnonymousFlowContext(BidiResolvedDirection.Ltr, "en", null))
            val offsets = AnonymousFlowOffsets.build(content,
                { event, source -> anonymousInlineSemantic(event.layoutSpans, source) }) { native }
            val selection = AnonymousFlowSelection.build(offsets) { error("No figure in this control") }
            val expected = "AB${alt.orEmpty()}!Z"
            assertEquals(expected, selection.text)
            assertEquals(expected.length - 1, selection.semanticOffset(4))
            assertEquals(4, selection.nativeOffset(expected.length - 1))
            assertEquals(link.text, selection.text.substring(selection.semanticOffset(4), selection.semanticOffset(5)))
            assertFalse(selection.text.contains('\ufffc'))
            if (!alt.isNullOrEmpty()) {
                for (offset in 2 until 2 + alt.length) assertEquals(2, selection.nativeOffset(offset))
                assertEquals(2 + alt.length, selection.semanticOffset(3))
            } else assertFalse(offsets.authored.any { it.replacement })
        }
        val empty = ruby(listOf(base(emptyList())), listOf(reading(0, emptyList())))
        assertEquals(emptyList<AnonymousInlineTextPart>(), anonymousInlineSemantic(listOf(empty), ""))
        assertEquals(listOf(AnonymousInlineTextPart(0, 1, "C")),
            anonymousInlineSemantic(listOf(empty, text("C")), "C"))
    }
}
