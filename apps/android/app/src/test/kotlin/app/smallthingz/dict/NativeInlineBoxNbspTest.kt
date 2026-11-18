package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativeInlineBoxNbspTest {
    private val body = "\u00a0\u00a0\u00a0\u00a0"
    private fun owner(linked: Boolean = false): Span {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edge = InlineBoxBorderEdge.Solid(StyleLength(StyleLengthUnit.Px, 1f), InlineBoxColor.Rgb("#000000"))
        return Span(if (linked) "link" else "text", "", if (linked) "original-target" else "",
            tooltip = "Controlled swatch title", background = "#cc2244", inlineBoxGroup = InlineBoxGroup(
                StyleEdges(zero, zero, zero, zero), InlineBoxBorderEdges(edge, edge, edge, edge),
                spans = listOf(Span("text", body))))
    }

    @Test fun blankLookingSwatchRetainsFourSourceOffsetsAndOwnerAdvice() {
        val owner = owner()
        val child = owner.inlineBoxGroup!!.spans.single()
        val period = Span("text", ".")
        val source = listOf(owner, period)
        val projection = rubyGraphicalProjection(source)
        assertTrue(body.isBlank())
        assertEquals(body + ".", projection.text)
        val range = projection.ranges.single { it.role == RubyTextRole.BoxGroup }
        assertEquals(0 to 4, range.start to range.end)
        assertSame(owner, range.span)
        assertSame(child, projection.ranges.single { it.span === child }.span)
        assertEquals(4, projection.ranges.single { it.span === period }.start)
        assertEquals(body, projection.text.substring(range.start, range.end))
        assertEquals("Controlled swatch title", NativeTextAdvisoryIndex(projection).title(range))
        val entry = Entry("swatch", emptyList(), "language", "Malagasy", "mg",
            listOf(Section(3, "Body", listOf(Block("paragraph", 0, source)))), emptyList())
        val detail = entry.textDetails.single { it.kind == TextDetailKind.Advisory }
        assertEquals(body, detail.label)
        assertEquals("Controlled swatch title", detail.description)
        assertTrue(source.hasCompiledInlineContent())
        assertFalse(owner.hasInternalAction()); assertFalse(child.hasInternalAction())
    }

    @Test fun literalNbspLinkedBoxKeepsExactlyItsOriginalActionAndChild() {
        // Existing literal Unicode records remain valid; this does not admit an entity-action producer.
        val owner = owner(linked = true)
        val child = owner.inlineBoxGroup!!.spans.single()
        val projection = rubyGraphicalProjection(listOf(owner))
        assertEquals(body, projection.text)
        assertEquals(1, projection.ranges.count { it.span?.hasInternalAction() == true })
        val action = projection.ranges.single { it.span?.hasInternalAction() == true }
        assertSame(owner, action.span)
        assertEquals(0 to 4, action.start to action.end)
        assertEquals(EntryLink("original-target"), owner.entryLink())
        assertSame(child, projection.ranges.single { it.span === child }.span)
        assertFalse(child.hasInternalAction())
        assertEquals("Controlled swatch title", NativeTextAdvisoryIndex(projection).title(action))
    }
}
