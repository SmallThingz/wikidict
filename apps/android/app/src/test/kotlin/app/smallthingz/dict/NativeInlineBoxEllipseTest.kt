package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativeInlineBoxEllipseTest {
    @Test fun halfPercentUsesBothBorderAxesAndKeepsHitInteriorIndependentFromDots() {
        val slice = nativeInlineBoxEllipseSlices(listOf(NativeFloatBounds(7f, 11f, 19f, 31f)),
            false, 50f, true, 1f).single()
        assertEquals(6.0, slice.shape.radiusX, 0.0)
        assertEquals(10.0, slice.shape.radiusY, 0.0)
        // An ellipse, not a circle clamped to the narrow axis.
        assertFalse(slice.contains(8f, 14f))
        assertTrue(slice.contains(13f, 12f))
        assertTrue(slice.contains(13f, 21f))
        assertFalse(slice.contains(19f, 21f))
        for (x in 0 until 24) for (y in 0 until 40) {
            val px = (x + .5) / 2.0
            val py = (y + .5) / 2.0
            val expected = ((px - 6.0) / 6.0) * ((px - 6.0) / 6.0) +
                ((py - 10.0) / 10.0) * ((py - 10.0) / 10.0) <= 1.0
            assertEquals(expected, slice.contains(7f + px.toFloat(), 11f + py.toFloat()))
        }
    }

    @Test fun percentageSliceKeepsUnsplitWidthAcrossNarrowCutsRtlAndActualHeights() {
        val boxes = listOf(NativeFloatBounds(10f, 0f, 13f, 24f),
            NativeFloatBounds(20f, 30f, 29f, 46f), NativeFloatBounds(5f, 70f, 33f, 94f))
        val ltr = nativeInlineBoxEllipseSlices(boxes, false, 25f, true, 1f)
        val rtl = nativeInlineBoxEllipseSlices(boxes, true, 25f, true, 1f)
        assertEquals(listOf(0.0, 3.0, 12.0), ltr.map { it.offset })
        assertEquals(listOf(37.0, 28.0, 0.0), rtl.map { it.offset })
        assertTrue((ltr + rtl).all { it.shape.width == 40.0 && it.shape.radiusX == 10.0 })
        assertEquals(listOf(6.0, 4.0, 6.0), ltr.map { it.shape.radiusY })
        assertFalse(ltr[1].contains(20.01f, 30.01f))
        assertTrue(ltr[2].contains(5.01f, 70.01f))
        assertTrue(rtl[2].contains(32.99f, 70.01f))
        assertFalse(rtl[0].contains(12.99f, .01f))
    }

    @Test fun authoredPercentAboveHalfNormalizesAxesWhilePixelRadiusStaysCircular() {
        val box = listOf(NativeFloatBounds(0f, 0f, 40f, 12f))
        val half = nativeInlineBoxEllipseSlices(box, false, 50f, true, 1.25f).single()
        val huge = nativeInlineBoxEllipseSlices(box, false, Float.MAX_VALUE, true, 1.25f).single()
        assertEquals(half, huge)
        val pixels = nativeInlineBoxEllipseSlices(box, false, 50f, false, 1.25f).single()
        assertEquals(6.0, pixels.shape.radiusX, 0.0)
        assertEquals(6.0, pixels.shape.radiusY, 0.0)
        val zero = nativeInlineBoxEllipseSlices(box, false, -0f, true, 0f).single()
        assertTrue(zero.contains(.01f, .01f))
        for (bad in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY))
            assertThrows(UnsupportedFloatLayout::class.java) { nativeInlineBoxEllipseSlices(box, false, bad, true, 1f) }
    }

    @Test fun nativeFloatPathRefusesLostFractionalWindowsButKeepsOrdinaryFractionalSlices() {
        val ordinary = NativeInlineBoxEllipseShape(100000.0, 24.0, 50000.0, 12.0, 1.25f)
        nativeInlineBoxEllipseNativePrecision(ordinary, 99990.25, 3.75)
        val lost = NativeInlineBoxEllipseShape(33554432.0, 24.0, 16777216.0, 12.0, 1f)
        assertThrows(UnsupportedFloatLayout::class.java) {
            nativeInlineBoxEllipseNativePrecision(lost, 16777216.25, 1.25)
        }
        // The existing pixel-solid route still uses bounded local corner windows.
        val legacy = nativeInlineBoxCornerSlices(List(1000) { i ->
            NativeFloatBounds(0f, i * 20f, 100f, i * 20f + 20f)
        }, false, 8f, 1f)
        assertEquals(100000.0, legacy.last().compositeWidth, 0.0)
        assertTrue(legacy[500].contains(.01f, 10000.01f))
    }

}
