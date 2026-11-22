package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Public StaticLayout/Painter alignment equations; native shaping is covered on device. */
class NativeTextWrapTest {
    private fun alignmentOffset(left: Int, right: Int, ltr: Boolean, alignment: NativeWrapAlignment) = when (alignment) {
        NativeWrapAlignment.Normal -> if (ltr) left else -right
        NativeWrapAlignment.Opposite -> if (ltr) -right else left
        NativeWrapAlignment.Center -> (left - right) shr 1
    }

    @Test fun signedFitKeepsPhysicalPaintCaretAndSelectionOffsetInBothDirectionsAndEveryAlignment() {
        val alignments = listOf(NativeWrapAlignment.Normal, NativeWrapAlignment.Opposite, NativeWrapAlignment.Center)
        for (ltr in listOf(false, true)) for (alignment in alignments)
            for ((left, right) in listOf(0 to 0, 7 to 4, 4 to 7)) for (extra in listOf(0L, 1L, 2L, 117L)) {
                val fit = nativeWrapFitIndents(left, right, extra, ltr, alignment)
                assertEquals(alignmentOffset(left, right, ltr, alignment), alignmentOffset(fit.first, fit.second, ltr, alignment))
                val gained = left.toLong() + right - fit.first - fit.second
                assertTrue(gained >= extra)
                assertTrue(gained <= extra + if (alignment == NativeWrapAlignment.Center) 1 else 0)
                if (extra == 0L) assertEquals(left to right, fit)
            }
    }

    @Test fun fitExtensionChangesOnlyItsAlignmentTrailingSideAndNeverChangesPhysicalInputs() {
        assertEquals(5 to -34, nativeWrapFitIndents(5, 6, 40L, true, NativeWrapAlignment.Normal))
        assertEquals(-35 to 6, nativeWrapFitIndents(5, 6, 40L, false, NativeWrapAlignment.Normal))
        assertEquals(-35 to 6, nativeWrapFitIndents(5, 6, 40L, true, NativeWrapAlignment.Opposite))
        assertEquals(5 to -34, nativeWrapFitIndents(5, 6, 40L, false, NativeWrapAlignment.Opposite))
        assertEquals(-16 to -15, nativeWrapFitIndents(5, 6, 41L, true, NativeWrapAlignment.Center))
    }

    @Test fun coordinateOverflowAndInvalidPhysicalInputsRefuseBeforeSignedArithmetic() {
        for (extra in listOf(Long.MAX_VALUE, 4L * TablePixelLimit))
            assertTrue(runCatching { nativeWrapFitIndents(0, 0, extra, true, NativeWrapAlignment.Center) }.exceptionOrNull() is UnsupportedFloatLayout)
        assertTrue(runCatching { nativeWrapFitIndents(-1, 0, 1, true, NativeWrapAlignment.Normal) }.isFailure)
        assertTrue(runCatching { nativeWrapFitIndents(0, 0, -1, true, NativeWrapAlignment.Normal) }.isFailure)
    }
}
