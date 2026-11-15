package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.RectF
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeHardLineBreakTest {
    private open class Source(override val text: String,
        private val line: (Int) -> Pair<Int, Int> = { 0 to text.length }) : FloatTextGeometry {
        override val width = 40
        override val height = 20
        override val nodes = emptyList<FloatInteractionNode>()
        override fun lineRange(offset: Int): Pair<Int, Int> = line(offset)
        override fun paint(canvas: Canvas) = error("No paint in this source-range control")
        override fun offsetForPosition(x: Float, y: Float): Int = error("No native point query")
        override fun rectsForRange(start: Int, end: Int): List<RectF> = error("No native rectangle query")
        override fun characterRects(start: Int, length: Int): List<RectF?> = error("No native character query")
        override fun caretRect(offset: Int): RectF = error("No native caret query")
        override fun visualOffset(offset: Int, direction: Int): Int = error("No native bidi query")
    }

    private fun retainedGaps(): FloatTextGeometry = object : Source("A\nbcD\n") {
        override fun visualLineRanges(offset: Int): List<Pair<Int, Int>> =
            if (offset in 2 until 4) listOf(2 to 4) else listOf(0 to 2, 4 to 6)
        override fun isHardLineBreak(offset: Int): Boolean {
            require(offset in text.indices)
            return false
        }
    }

    @Test fun ordinaryEndKeepsItsOriginalLfTrimmingAndEmptyBehavior() {
        val source = Source("ab\ncd\n") { offset -> if (offset < 3) 0 to 3 else 3 to 6 }
        for (offset in source.text.indices)
            assertEquals(source.text[offset] == '\n', source.isHardLineBreak(offset))
        for (offset in 0..source.text.length) {
            val oldEnd = source.lineRange(offset).second.let {
                if (it > 0 && source.text[it - 1] == '\n') it - 1 else it
            }
            assertEquals(oldEnd, source.visualLineEnd(offset))
        }
        assertEquals(2, source.visualLineEnd(1))
        assertEquals(5, source.visualLineEnd(4))
        assertEquals(0, Source("").visualLineEnd(0))
        assertEquals(4, Source("A\ud83d\ude00B").visualLineEnd(2))
    }

    @Test fun retainedRubyLfAtTheLastVisualFragmentIsNotRemovedOrTurnedIntoAnotherRow() {
        val source = retainedGaps()
        assertEquals('\n', source.text[5])
        assertFalse(source.isHardLineBreak(5))
        assertFalse(source.isHardLineBreak(1))
        assertEquals(listOf(0 to 2, 4 to 6), source.visualLineRanges(0))
        assertEquals(6, source.visualLineEnd(0))
        assertEquals(6, source.visualLineEnd(5))
        assertEquals(4, source.visualLineEnd(2))
        assertEquals(4 to 6, source.visualLineFragment(5))
        assertEquals("D\n", source.text.substring(4, source.visualLineEnd(5)))
        assertEquals("bc", source.text.substring(2, source.visualLineEnd(2)))
    }

    @Test fun surfaceAndSemanticOffsetsKeepGapAuthoritySeparateFromTheirRealSeparator() {
        val source = retainedGaps()
        val surface = NativeSurfaceGeometry(source, NativeSurfaceBox(-7, -11, 60, 50))
        val group = NativeSemanticGroup(100, 80, listOf(
            PositionedSemanticChild(Source("Q"), 0f, 0f, BidiResolvedDirection.Ltr),
            PositionedSemanticChild(surface, 17.5f, 30.25f, BidiResolvedDirection.Rtl, "\n")))
        assertEquals("Q\nA\nbcD\n", group.text)
        assertTrue(group.isHardLineBreak(1))
        assertFalse(group.isHardLineBreak(3))
        assertFalse(group.isHardLineBreak(7))
        assertFalse(surface.isHardLineBreak(5))
        assertEquals(6, surface.visualLineEnd(0))
        assertEquals(listOf(2 to 4, 6 to 8), group.visualLineRanges(2))
        assertEquals(8, group.visualLineEnd(2))
        assertEquals(8, group.visualLineEnd(7))
        assertEquals(6, group.visualLineEnd(4))
        assertEquals(source.text, group.text.substring(2))
    }

    @Test fun paragraphMovementUsesOnlyHardBreaksAndPreservesOrdinaryLfParity() {
        for (text in listOf("", "ab", "\n", "ab\ncd\n", "a\n\nb", "A\ud83d\ude00\nB")) {
            val ordinary = Source(text)
            for (offset in 0..text.length) {
                val oldForward = text.indexOf('\n', offset).let { if (it < 0) text.length else it + 1 }
                val oldBackward = text.lastIndexOf('\n', maxOf(-1, offset - 2)).let { it + 1 }
                assertEquals(oldForward, ordinary.paragraphBoundary(offset, true))
                assertEquals(oldBackward, ordinary.paragraphBoundary(offset, false))
            }
        }
        val projected = object : Source("p\nA\r\n\tB") {
            override fun isHardLineBreak(offset: Int): Boolean {
                require(offset in text.indices)
                return offset == 1
            }
        }
        assertEquals('\n', projected.text[4])
        assertFalse(projected.isHardLineBreak(4))
        assertEquals(2, projected.paragraphBoundary(0, true))
        assertEquals(7, projected.paragraphBoundary(2, true))
        assertEquals(7, projected.paragraphBoundary(4, true))
        assertEquals(2, projected.paragraphBoundary(7, false))
        assertEquals(2, projected.paragraphBoundary(5, false))
        assertEquals(0, projected.paragraphBoundary(2, false))
        assertEquals("A\r\n\tB", projected.text.substring(2, projected.paragraphBoundary(2, true)))
    }
}
