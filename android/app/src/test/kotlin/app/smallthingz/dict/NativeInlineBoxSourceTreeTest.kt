package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativeInlineBoxSourceTreeTest {
    private fun px(amount: Int) = StyleLength(StyleLengthUnit.Px, amount.toFloat())
    private val none = InlineBoxBorderEdge.None
    private fun wrap(children: List<Span>, left: Int = 0, right: Int = 0,
        bottom: InlineBoxBorderEdge = none) = Span("text", "", inlineBoxGroup = InlineBoxGroup(
            StyleEdges(px(0), px(right), px(0), px(left)), InlineBoxBorderEdges(none, none, bottom, none), spans = children))
    private fun help() = wrap(listOf(Span("text", "c", italic = true)), bottom =
        InlineBoxBorderEdge.Dotted(px(1), InlineBoxColor.Rgb("#000000"))).copy(
            tooltip = "Cantonese", inlineStyle = InlineTextStyle(cursor = InlineCursor.Help))
    private fun link(label: String, lang: String, script: String) = Span("link", label, target = label,
        targetFragment = "Chinese", language = lang, classes = script)
    @Test fun coincidentPaintOwnersFollowTheirDecodedSourceChildren() {
        val tips = listOf(help(), help())
        val gap = wrap(listOf(Span("text", "\u00a0")), 4, 4)
        val fill = wrap(listOf(Span("text", "("), Span("text", "Класификатор", italic = true),
            Span("text", ": "), link("隻", "zh-Hant", "Hant"), Span("text", "／"), link("只", "zh", "Hani"),
            Span("text", " "), tips[0], Span("text", ";"), gap, link("個", "zh-Hant", "Hant"),
            Span("text", "／"), link("个", "zh-Hans", "Hans"), Span("text", " "), tips[1], Span("text", ")")))
            .copy(background = "#edffff")
        val outer = wrap(listOf(fill), 15).copy(fontScale = .8f)
        val projection = rubyGraphicalProjection(listOf(outer))
        assertEquals("(Класификатор: 隻／只 c;\u00a0個／个 c)", projection.text)
        val boxes = projection.ranges.filter { it.role == RubyTextRole.BoxGroup }.map {
            InlineBoxOccurrence(it.path, checkNotNull(it.span), it.start, it.end)
        }.reversed()
        fun index(span: Span) = boxes.indices.single { boxes[it].owner === span }
        val parents = checkNotNull(inlineBoxSourceParents(boxes))
        assertTrue(nativeInlineSimplePaintTree(outer))
        assertEquals(-1, parents[index(outer)])
        assertEquals(index(outer), parents[index(fill)])
        for (child in tips + gap) assertEquals(index(fill), parents[index(child)])
        val first = index(tips[0]); val last = index(tips[1])
        fun altered(i: Int, occurrence: InlineBoxOccurrence) = boxes.mapIndexed { at, old -> if (at == i) occurrence else old }
        assertNull(inlineBoxSourceParents(altered(first, boxes[first].copy(owner = tips[1]))))
        assertNull(inlineBoxSourceParents(altered(last, boxes[last].copy(start = boxes[first].start))))
        assertNull(inlineBoxSourceParents(boxes.filterIndexed { at, _ -> at != index(fill) }))
    }

    @Test fun threeOwnersWithIdenticalTextIntervalsKeepParentOrderAndRejectStructuralReordering() {
        val leaf = wrap(listOf(Span("text", "X", italic = true)), 2, 3).copy(fontScale = 1.5f)
        val fill = wrap(listOf(leaf), 5).copy(background = "#edffff")
        val outer = wrap(listOf(fill), 15)
        val boxes = rubyGraphicalProjection(listOf(outer)).ranges.filter { it.role == RubyTextRole.BoxGroup }
            .map { InlineBoxOccurrence(it.path, checkNotNull(it.span), it.start, it.end) }
        assertTrue(boxes.all { it.start == 0 && it.end == 1 })
        val parents = checkNotNull(inlineBoxSourceParents(boxes))
        fun parentOf(owner: Span): Span {
            val index = boxes.indexOfFirst { it.owner === owner }
            return boxes[parents[index]].owner
        }
        assertSame(fill, parentOf(leaf))
        assertSame(outer, parentOf(fill))
        assertFalse(nativeInlineSimplePaintTree(outer.copy(direction = "rtl")))
        assertFalse(nativeInlineSimplePaintTree(wrap(listOf(Span("text", "X", superscript = true)))))
        val first = wrap(listOf(Span("text", "A")))
        val second = wrap(listOf(Span("text", "B")))
        val two = wrap(listOf(first, second))
        val siblings = rubyGraphicalProjection(listOf(two)).ranges.filter { it.role == RubyTextRole.BoxGroup }
            .map { InlineBoxOccurrence(it.path, checkNotNull(it.span), it.start, it.end) }
        assertNotNull(inlineBoxSourceParents(siblings))
        assertNull(inlineBoxSourceParents(siblings.map { when {
            it.owner === first -> it.copy(start = 1, end = 2)
            it.owner === second -> it.copy(start = 0, end = 1)
            else -> it
        } }))
    }
}
