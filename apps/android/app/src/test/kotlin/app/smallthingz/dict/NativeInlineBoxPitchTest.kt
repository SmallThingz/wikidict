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
}
