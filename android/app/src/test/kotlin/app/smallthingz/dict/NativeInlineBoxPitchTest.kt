package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Typed ranges from the six retained MG pitch sources; no rendered-page claim. */
class NativeInlineBoxPitchTest {
    private val cases = listOf(
        listOf("ロ" to false, "ス" to true, "コ" to false),
        listOf("ヌ" to true, "エッ" to false, "チ" to true, "ケ" to false),
        listOf("ラリン" to false, "ピ" to true),
        listOf("エズ" to false, "ス" to true),
        listOf("た" to false, "く" to true, "ちい" to false),
        listOf("ス" to true, "カ" to false))
    private val zero = StyleLength(StyleLengthUnit.Px, 0f)
    private val one = StyleLength(StyleLengthUnit.Px, 1f)
    private val empty = StyleEdges(zero, zero, zero, zero)
    private val none = InlineBoxBorderEdge.None
    private val solid = InlineBoxBorderEdge.Solid(one, InlineBoxColor.CurrentColor)
    private val dotted = InlineBoxBorderEdge.Dotted(one, InlineBoxColor.Rgb("#808080"))
    private fun text(value: String) = Span("text", value, language = "ja", classes = "Jpan")
    private fun circle(value: String) = text("").copy(inlineBoxGroup = InlineBoxGroup(empty,
        InlineBoxBorderEdges(dotted, dotted, dotted, dotted), spans = listOf(text(value)),
        radius = StyleWidth(StyleWidthUnit.Percent, 50f)))
    private fun pitch(segments: List<Pair<String, Boolean>>) = text("").copy(inlineBoxGroup = InlineBoxGroup(
        StyleEdges(one, one, one, one), InlineBoxBorderEdges(solid, none, none, none),
        overlays = listOf(InlineBoxOverlay(InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, 0f),
            right = InlineBoxInset(StyleWidthUnit.Percent, 0f), bottom = InlineBoxInset(StyleWidthUnit.Percent, 67f)),
            InlineBoxBorderEdges(none, solid, none, none))),
        spans = segments.map { if (it.second) circle(it.first) else text(it.first) }))

    @Test fun sixRetainedPitchShapesKeepOriginalChildrenRangesAndEndpointOwnership() {
        for (segments in cases) {
            val owner = pitch(segments)
            val children = checkNotNull(nativeInlineBoxPitchChildren(owner))
            val original = checkNotNull(owner.inlineBoxGroup).spans.filter { it.inlineBoxGroup != null }
            assertEquals(original.size, children.size)
            original.zip(children).forEach { (a, b) -> assertSame(a, b) }
            val projection = rubyGraphicalProjection(listOf(text("前"), owner, text("後")))
            assertEquals("前" + segments.joinToString("") { it.first } + "後", projection.text)
            val ranges = projection.ranges.filter { it.role == RubyTextRole.BoxGroup }
            val root = ranges.indexOfFirst { it.span === owner }
            val parents = checkNotNull(nativeInlineBoxNestedParents(ranges.map { it.start to it.end }, setOf(root)))
            assertEquals(-1, parents[root])
            assertEquals(1 to (projection.text.length - 1), ranges[root].start to ranges[root].end)
            var offset = 1
            for ((segment, decorated) in segments) {
                if (decorated) {
                    val expected = children.single { it.inlineBoxGroup!!.spans.single().text == segment }
                    val at = ranges.indexOfFirst { it.span === expected }
                    assertEquals(offset to offset + 1, ranges[at].start to ranges[at].end)
                    assertEquals(root, parents[at])
                }
                offset += segment.length
            }
            assertEquals(children.size + 1, ranges.size)
        }
    }

    @Test fun pitchAdmissionRequiresExactAuthoredPaddingCircleAndEmptyIndicatorUnits() {
        val owner = pitch(cases.first())
        val box = checkNotNull(owner.inlineBoxGroup)
        val indicator = box.overlays.single()
        val child = box.spans[1]
        val circle = checkNotNull(child.inlineBoxGroup)
        fun outer(value: InlineBoxGroup) = owner.copy(inlineBoxGroup = value)
        fun inner(value: InlineBoxGroup) = outer(box.copy(spans = listOf(box.spans[0], child.copy(inlineBoxGroup = value), box.spans[2])))
        val em = StyleLength(StyleLengthUnit.Em, 1f)
        val changed = listOf(
            outer(box.copy(padding = StyleEdges(em, em, em, em))),
            outer(box.copy(border = box.border.copy(top = solid.copy(color = InlineBoxColor.Rgb("#000000"))))),
            outer(box.copy(overlays = listOf(indicator.copy(insets = indicator.insets.copy(bottom = InlineBoxInset(StyleWidthUnit.Percent, 66f)))))),
            outer(box.copy(overlays = listOf(indicator.copy(insets = indicator.insets.copy(right = InlineBoxInset(StyleWidthUnit.Px, 0f)))))),
            outer(box.copy(overlays = emptyList())),
            inner(circle.copy(padding = StyleEdges(one, one, one, one))),
            inner(circle.copy(radius = StyleWidth(StyleWidthUnit.Percent, 49f))),
            inner(circle.copy(border = InlineBoxBorderEdges(dotted.copy(width = StyleLength(StyleLengthUnit.Px, 2f)),
                dotted.copy(width = StyleLength(StyleLengthUnit.Px, 2f)), dotted.copy(width = StyleLength(StyleLengthUnit.Px, 2f)),
                dotted.copy(width = StyleLength(StyleLengthUnit.Px, 2f)))))
        )
        changed.forEach { assertNull(nativeInlineBoxPitchChildren(it)) }
        assertNotNull(nativeInlineBoxPitchChildren(owner))
    }

    @Test fun pitchTopologyRejectsEqualCrossedDeepAdjacentAndUnownedRanges() {
        for (ranges in listOf(
                listOf(0 to 5, 0 to 5), listOf(0 to 5, 4 to 6), listOf(0 to 5, 1 to 4, 2 to 3),
                listOf(0 to 5, 1 to 2, 2 to 3), listOf(0 to 7, 0 to 1, 2 to 3, 4 to 5),
                listOf(0 to 5, 1 to 3)))
            assertNull(nativeInlineBoxNestedParents(ranges, setOf(0)))
        assertNull(nativeInlineBoxNestedParents(listOf(0 to 3, 0 to 1), setOf(2)))
        assertNull(nativeInlineBoxNestedParents(listOf(0 to 3, 0 to 1)))
        assertEquals(listOf(1, -1, 1, -1), nativeInlineBoxNestedParents(
            listOf(0 to 1, 0 to 5, 3 to 4, 6 to 8), setOf(1)))
        assertEquals(listOf(-1, 0), nativeInlineBoxNestedParents(listOf(0 to 3, 2 to 3), setOf(0)))
        assertEquals(listOf(-1, 0), nativeInlineBoxNestedParents(listOf(0 to 5, 1 to 3)))
    }

    @Test fun pitchSourceRejectsHelpActionsStructuralDescendantsAndMultiCharacterCircles() {
        val owner = pitch(cases.first())
        val box = checkNotNull(owner.inlineBoxGroup)
        val child = box.spans[1]
        val childBox = checkNotNull(child.inlineBoxGroup)
        fun withChild(value: Span) = owner.copy(inlineBoxGroup = box.copy(spans = listOf(box.spans[0], value, box.spans[2])))
        val changed = listOf(owner.copy(tooltip = "Pitch"), owner.copy(direction = "rtl"),
            withChild(child.copy(tooltip = "Circle")),
            withChild(Span("link", "", "Target", inlineBoxGroup = childBox)),
            withChild(child.copy(inlineBoxGroup = childBox.copy(spans = listOf(text("スス"))))),
            withChild(child.copy(inlineBoxGroup = childBox.copy(spans = listOf(text("ス\u202e"))))),
            withChild(child.copy(inlineBoxGroup = childBox.copy(spans = listOf(circle("ス"))))),
            owner.copy(inlineBoxGroup = box.copy(spans = listOf(child, text("中"), child))))
        changed.forEach { assertNull(nativeInlineBoxPitchChildren(it)) }
        assertNotNull(nativeInlineBoxPitchChildren(owner))
    }

    @Test fun retainedPegasusLevelPitchUsesStrictInteriorTopologyAndKeepsOutsideActions() {
        // Retained Pegasus Reader, first pronunciation cell, spans 0..14.
        // This level pitch has no drop indicator; null pitch children select the legacy branch.
        val child = circle("ス")
        val childText = checkNotNull(child.inlineBoxGroup).spans.single()
        val before = text("ガ")
        val after = text("スざ")
        val owner = text("").copy(inlineBoxGroup = InlineBoxGroup(empty,
            InlineBoxBorderEdges(solid, none, none, none), spans = listOf(before, child, after)))
        val tokyo = Span("external_link", "Tokyo", "https://mg.wikipedia.org/wiki/Tokyo_dialect",
            classes = "usage-label-accent ib-content label-content extiw", role = "label")
        val heiban = Span("link", "Heiban", "平板型")
        val brac = "usage-label-accent ib-brac label-brac"
        val source = listOf(Span("text", "• "), Span("text", "(", classes = brac), tokyo,
            Span("text", ")", classes = brac), Span("text", " "), text("ペ"), owner, Span("text", " "),
            Span("text", "[pègás", classes = "Latn", code = true),
            Span("text", "ú", classes = "Latn", code = true, strike = true),
            Span("text", "súzá]", classes = "Latn", code = true), Span("text", " ("), heiban,
            Span("text", " – [0])"), Span("line_break", "\n"))
        val projection = rubyGraphicalProjection(source, "pegasus/pronunciation")
        val expected = "• (Tokyo) ペガススざ [pègásúsúzá] (Heiban – [0])\n"
        assertEquals(expected, projection.text)
        assertEquals(expected, rubyBaseText(source))
        val boxes = projection.ranges.filter { it.role == RubyTextRole.BoxGroup }
        assertEquals(2, boxes.size)
        assertSame(owner, boxes[0].span)
        assertSame(child, boxes[1].span)
        assertEquals(11 to 15, boxes[0].start to boxes[0].end)
        assertEquals(12 to 13, boxes[1].start to boxes[1].end)
        assertEquals("pegasus/pronunciation/spans/6", boxes[0].path)
        assertEquals(boxes[0].path + "/inlineBoxGroup/spans/1", boxes[1].path)
        assertNull(nativeInlineBoxPitchChildren(owner))
        val pitchParents = boxes.indices.filter { nativeInlineBoxPitchChildren(checkNotNull(boxes[it].span)) != null }.toSet()
        assertTrue(pitchParents.isEmpty())
        assertEquals(listOf(-1, 0), nativeInlineBoxNestedParents(boxes.map { it.start to it.end }, pitchParents))
        // Keep strict-interior refusal at either endpoint in this branch.
        assertNull(nativeInlineBoxNestedParents(listOf(11 to 15, 11 to 12), pitchParents))
        assertNull(nativeInlineBoxNestedParents(listOf(11 to 15, 14 to 15), pitchParents))
        val leaves = projection.ranges.filter { it.role == RubyTextRole.Text }
        for ((span, interval) in listOf(before to (11 to 12), childText to (12 to 13), after to (13 to 15),
                tokyo to (3 to 8), heiban to (30 to 36))) {
            val range = leaves.single { it.span === span }
            assertEquals(interval, range.start to range.end)
            assertEquals(span.text, projection.text.substring(range.start, range.end))
        }
        assertEquals(boxes[1].path + "/inlineBoxGroup/spans/0", leaves.single { it.span === childText }.path)
        val actions = leaves.filter { it.span?.kind in setOf("link", "external_link") }
        assertEquals(2, actions.size)
        assertSame(tokyo, actions[0].span)
        assertSame(heiban, actions[1].span)
        assertTrue(actions[0].end <= boxes[0].start && actions[1].start >= boxes[0].end)
        val flattened = rubyGraphicalSpans(source)
        assertEquals(expected, flattened.joinToString("") { it.text + it.trail })
        assertSame(tokyo, flattened.single { it.kind == "external_link" })
        assertSame(heiban, flattened.single { it.kind == "link" })
        assertSame(source[9], flattened.single { it.strike })
    }
}
