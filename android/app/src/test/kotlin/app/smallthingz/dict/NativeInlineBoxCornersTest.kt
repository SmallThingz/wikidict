package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativeInlineBoxCornersTest {
    private fun expected(width: Double, height: Double, authored: Double, x: Double, y: Double): Boolean {
        if (x < 0.0 || x >= width || y < 0.0 || y >= height) return false
        val r = minOf(authored, width / 2.0, height / 2.0)
        val dx = when { x < r -> r - x; x > width - r -> x - (width - r); else -> 0.0 }
        val dy = when { y < r -> r - y; y > height - r -> y - (height - r); else -> 0.0 }
        return dx == 0.0 || dy == 0.0 || dx * dx + dy * dy <= r * r
    }

    @Test fun narrowFirstSliceRetainsCompositeCornerAcrossTheNextLine() {
        val boxes = listOf(NativeFloatBounds(10f, 20f, 14f, 40f), NativeFloatBounds(3f, 70f, 39f, 90f))
        val slices = nativeInlineBoxCornerSlices(boxes, false, 8f, 1f)
        assertEquals(listOf(0.0, 4.0), slices.map { it.offset })
        assertTrue(slices.all { it.compositeWidth == 40.0 })
        assertEquals(8.0, slices[0].localShape.outerRadii.topLeft, 0.0)
        assertFalse(slices[1].contains(3.25f, 70.25f)) // The original start corner continues across the cut.
        assertTrue(slices[1].contains(3.25f, 80f))
        var accumulated = 0.0
        slices.forEach { slice ->
            val box = slice.fragment
            for (ix in 0 until ((box.right - box.left) * 4).toInt()) for (iy in 0 until 80) {
                val x = (ix + .5) / 4.0; val y = (iy + .5) / 4.0
                assertEquals(expected(40.0, 20.0, 8.0, accumulated + x, y),
                    slice.contains(box.left + x.toFloat(), box.top + y.toFloat()))
            }
            accumulated += box.right - box.left
        }
        // The narrow first slice would incorrectly normalize to 2px if rounded independently.
        assertFalse(expected(40.0, 20.0, 8.0, 2.0, .5))
        assertTrue(expected(4.0, 20.0, 8.0, 2.0, .5))
    }

    @Test fun rtlProgressionAndDifferentFragmentHeightsUseTheSameUnbrokenWidth() {
        val boxes = listOf(NativeFloatBounds(100f, 10f, 103f, 34f),
            NativeFloatBounds(20f, 60f, 29f, 76f), NativeFloatBounds(40f, 100f, 68f, 124f))
        val ltr = nativeInlineBoxCornerSlices(boxes, false, 9f, 1.25f)
        val rtl = nativeInlineBoxCornerSlices(boxes, true, 9f, 1.25f)
        assertEquals(listOf(0.0, 3.0, 12.0), ltr.map { it.offset })
        assertEquals(listOf(37.0, 28.0, 0.0), rtl.map { it.offset })
        for (parts in listOf(ltr, rtl)) for (slice in parts) {
            val box = slice.fragment; val height = (box.bottom - box.top).toDouble()
            for (ix in 0 until ((box.right - box.left) * 2).toInt()) for (iy in 0 until (height * 2).toInt()) {
                val x = (ix + .5) / 2.0; val y = (iy + .5) / 2.0
                assertEquals(expected(40.0, height, 9.0, slice.offset + x, y),
                    slice.contains(box.left + x.toFloat(), box.top + y.toFloat()))
            }
        }
        assertEquals(8.0, ltr[1].localShape.outerRadii.topLeft, 0.0) // This piece's height, not a new width clamp.
        assertEquals(6.75, ltr[1].localShape.innerRadii.topLeft, 0.0)
        assertTrue(ltr[2].contains(40.01f, 100.01f)) // Interior cut is square, with no fresh corner.
        assertTrue(rtl[2].contains(67.99f, 100.01f))
    }

    @Test fun compositeLongerThanPhysicalCoordinateLimitKeepsLocalPaintGeometryBounded() {
        val boxes = List(1000) { index -> NativeFloatBounds(2f, index * 20f, 102f, index * 20f + 20f) }
        val slices = nativeInlineBoxCornerSlices(boxes, false, 100f, 1f)
        assertEquals(100000.0, slices.first().compositeWidth, 0.0)
        assertEquals(99900.0, slices.last().offset, 0.0)
        slices.forEach { slice ->
            assertEquals(10.0, slice.localShape.outerRadii.topLeft, 0.0)
            assertTrue(slice.localShape.borderBox.left >= -20f)
            assertTrue(slice.localShape.borderBox.right <= 120f)
        }
        assertTrue(slices[500].contains(2.01f, 10000.01f))
        assertFalse(slices.first().contains(2.01f, .01f))
        assertFalse(slices.last().contains(101.99f, 19980.01f))
    }

    @Test fun zeroRadiusAndZeroBorderRetainTheirDistinctAuthoredGeometry() {
        val box = NativeFloatBounds(1.25f, 2.5f, 31.75f, 15.5f)
        val square = nativeInlineBoxCornerSlices(listOf(box), false, -0f, 1.25f).single()
        assertTrue(square.contains(1.251f, 2.501f))
        assertEquals(0.0, square.localShape.outerRadii.topLeft, 0.0)
        val rounded = nativeInlineBoxCornerSlices(listOf(box), false, 2.5f, -0f).single()
        assertEquals(rounded.localShape.outerRadii, rounded.localShape.innerRadii)
        assertEquals(rounded.localShape.borderBox, rounded.localShape.paddingBox)
        assertFalse(rounded.contains(1.251f, 2.501f))
        assertTrue(rounded.contains(4f, 3f))
        assertThrows(UnsupportedFloatLayout::class.java) {
            nativeInlineBoxCornerSlices(listOf(NativeFloatBounds(0f, 0f, 0f, 20f)), false, 2f, 1f)
        }
        assertTrue(nativeInlineBoxCornerSlices(listOf(box), false, 2.5f, 0f).single().contains(4f, 3f))
    }
}
