package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.RectF
import org.junit.Assert.*
import org.junit.Test

/** Pure range controls; the Ruby shaper and device navigation remain separately unrun. */
class NativeVisualLineRangesTest {
    private open class Source(override val text: String,
        private val line: (Int) -> Pair<Int, Int> = { 0 to text.length }) : FloatTextGeometry {
        override val width = 40
        override val height = 20
        override val nodes = emptyList<FloatInteractionNode>()
        override fun lineRange(offset: Int): Pair<Int, Int> {
            require(offset in 0..text.length)
            return line(offset)
        }
        override fun paint(canvas: Canvas) = error("No paint in this range control")
        override fun offsetForPosition(x: Float, y: Float): Int = error("No point layout in this range control")
        override fun rectsForRange(start: Int, end: Int): List<RectF> = error("No rectangles in this range control")
        override fun characterRects(start: Int, length: Int): List<RectF?> = error("No rectangles in this range control")
        override fun caretRect(offset: Int): RectF = error("No caret layout in this range control")
        override fun visualOffset(offset: Int, direction: Int): Int = error("No bidi layout in this range control")
    }

    private fun fragmented(): FloatTextGeometry = object : Source("A\uD83D\uDE00BcdEF") {
        override fun visualLineRanges(offset: Int): List<Pair<Int, Int>> {
            require(offset in 0..text.length)
            return if (offset in 4 until 6) listOf(4 to 6) else listOf(0 to 4, 6 to 8)
        }
    }

    @Test fun unchangedOwnersRetainEveryOriginalLineAndEmptyEnd() {
        val ordinary = Source("ab\ncd") { offset -> if (offset < 3) 0 to 3 else 3 to 5 }
        for (offset in 0..ordinary.text.length) {
            assertEquals(listOf(ordinary.lineRange(offset)), ordinary.visualLineRanges(offset))
            assertEquals(ordinary.lineRange(offset), ordinary.visualLineFragment(offset))
        }
        assertEquals(0 to 3, ordinary.visualLineFragment(2))
        assertEquals(3 to 5, ordinary.visualLineFragment(3))
        val empty = Source("")
        assertEquals(listOf(0 to 0), empty.visualLineRanges(0))
        assertEquals(0 to 0, empty.visualLineFragment(0))
    }

    @Test fun lineMovementDoesNotReportTheOtherRowBetweenSourceFragments() {
        val source = fragmented()
        assertEquals(8, source.text.length)
        assertEquals(0 to 8, source.lineRange(1)) // The legacy envelope is deliberately unsuitable.
        assertEquals(listOf(0 to 4, 6 to 8), source.visualLineRanges(1))
        assertEquals(0 to 4, source.visualLineFragment(1))
        assertEquals(0 to 4, source.visualLineFragment(2)) // Low surrogate is still a UTF-16 offset.
        assertEquals(4 to 6, source.visualLineFragment(4))
        assertEquals(6 to 8, source.visualLineFragment(6))
        assertEquals(6 to 8, source.visualLineFragment(8))
        val first = checkNotNull(source.visualLineFragment(1))
        val last = checkNotNull(source.visualLineFragment(7))
        assertEquals("A\uD83D\uDE00B", source.text.substring(first.first, first.second))
        assertEquals("EF", source.text.substring(last.first, last.second))
        assertFalse(source.text.substring(first.first, first.second).contains("cd"))
        assertFalse(source.text.substring(last.first, last.second).contains("cd"))
    }

    @Test fun translatedSurfaceAndSemanticOwnerKeepEachOriginalFragment() {
        val source = fragmented()
        val surface = NativeSurfaceGeometry(source, NativeSurfaceBox(-7, -11, 60, 50))
        val group = NativeSemanticGroup(100, 80, listOf(
            PositionedSemanticChild(Source("Q"), 0f, 0f, BidiResolvedDirection.Ltr),
            PositionedSemanticChild(surface, 17.5f, 30.25f, BidiResolvedDirection.Rtl, "\n")))
        assertEquals("Q\nA\uD83D\uDE00BcdEF", group.text)
        assertEquals(listOf(0 to 4, 6 to 8), surface.visualLineRanges(2))
        assertEquals(listOf(2 to 6, 8 to 10), group.visualLineRanges(4))
        assertEquals(2 to 6, group.visualLineFragment(4))
        assertEquals(listOf(6 to 8), group.visualLineRanges(6))
        assertEquals(8 to 10, group.visualLineFragment(9))
        assertEquals(8 to 10, group.visualLineFragment(10))
        assertEquals(listOf(0 to 1), group.visualLineRanges(0))
        val ordinary = NativeSemanticGroup(100, 80, listOf(
            PositionedSemanticChild(Source("ab"), 0f, 0f, BidiResolvedDirection.Ltr),
            PositionedSemanticChild(Source("cd"), 0f, 20f, BidiResolvedDirection.Rtl, "\n\n")))
        for (offset in 0..ordinary.text.length)
            assertEquals(listOf(ordinary.lineRange(offset)), ordinary.visualLineRanges(offset))
    }

    @Test fun absentFragmentDoesNotInventMovementAcrossAnotherRow() {
        val gap = object : Source("abcdefgh") {
            override fun visualLineRanges(offset: Int) = listOf(0 to 2, 6 to 8)
        }
        assertNull(gap.visualLineFragment(4))
        val empty = object : Source("") {
            override fun visualLineRanges(offset: Int) = emptyList<Pair<Int, Int>>()
        }
        assertNull(empty.visualLineFragment(0))
        val adjacent = object : Source("abcd") {
            override fun visualLineRanges(offset: Int) = listOf(0 to 2, 2 to 4)
        }
        assertEquals(2 to 4, adjacent.visualLineFragment(2))
        assertEquals(2 to 4, adjacent.visualLineFragment(4))
    }
}
