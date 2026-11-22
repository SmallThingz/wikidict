package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativeTableCornersTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)

    @Test fun sourcePixelsResolveOnceAndAllCornersUseOneFinalBoxFactor() {
        val source = TableCornerRadii(px(8f), px(8f), px(8f), px(0f))
        val physical = nativeTableCornerRadii(source, 1.25f)
        assertEquals(NativeCornerRadii(10f, 10f, 10f, 0f), physical)
        val ordinary = NativeTableCornerShape(NativeFloatBounds(.25f, .75f, 60.25f, 30.75f), physical, 1.25f)
        assertEquals(physical, ordinary.outerRadii)
        assertEquals(NativeCornerRadii(8.75f, 8.75f, 8.75f, 0f), ordinary.innerRadii)
        assertEquals(NativeFloatBounds(1.5f, 2f, 59f, 29.5f), ordinary.paddingBox)
        val constrained = NativeTableCornerShape(NativeFloatBounds(0f, 0f, 20f, 10f),
            NativeCornerRadii(20f, 10f, 5f, 0f), 0f)
        // The left vertical sum sets f=.5; independently clipping each radius gives a different tuple.
        assertEquals(NativeCornerRadii(10f, 5f, 2.5f, 0f), constrained.outerRadii)
        assertEquals(constrained.outerRadii, constrained.innerRadii)
        assertEquals(8f, source.topLeft.value, 0f)
    }

    @Test fun tinyFractionalBoxRetainsMixedZeroCornersAndClosedCircleShape() {
        val shape = NativeTableCornerShape(NativeFloatBounds(.25f, .5f, 3.75f, 2.75f),
            NativeCornerRadii(8f, 8f, 8f, 0f), .25f)
        assertEquals(NativeCornerRadii(1.125f, 1.125f, 1.125f, 0f), shape.outerRadii)
        assertEquals(NativeCornerRadii(.875f, .875f, .875f, 0f), shape.innerRadii)
        assertFalse(shape.contains(.3f, .55f))
        assertTrue(shape.contains(.3f, 2.7f)) // Physical bottom-left remains square.
        assertTrue(shape.contains(2f, 1.5f, padding = true))
        assertFalse(shape.contains(3.75f, 1.5f))
        assertFalse(shape.contains(2f, 2.75f))
        assertFalse(shape.contains(Float.NaN, 1f))
    }

    @Test fun innerOppositeBorderOverlapIsIntersectionRatherThanRenormalizedRoundRect() {
        val shape = NativeTableCornerShape(NativeFloatBounds(0f, 0f, 10f, 10f),
            NativeCornerRadii(0f, 10f, 0f, 0f), 2f)
        assertEquals(NativeFloatBounds(2f, 2f, 8f, 8f), shape.paddingBox)
        assertEquals(8.0, shape.innerRadii.topRight, 0.0) // It deliberately exceeds padding width 6.
        assertTrue(shape.contains(2.1f, 2.1f))
        assertFalse(shape.contains(2.1f, 2.1f, padding = true))
        assertTrue(shape.contains(3f, 3f, padding = true))
        val renormalized = NativeTableCornerShape(checkNotNull(shape.paddingBox),
            NativeCornerRadii(0f, 8f, 0f, 0f), 0f)
        assertTrue(renormalized.contains(2.1f, 2.1f)) // Explicit counterexample to the forbidden operation.
        val noHole = NativeTableCornerShape(shape.borderBox, NativeCornerRadii(8f, 8f, 8f, 0f), 5f)
        assertNull(noHole.paddingBox)
        assertFalse(noHole.contains(5f, 5f, padding = true))
    }

    @Test fun projectionKeepsAlreadyNormalizedRadiiAndEmptyGeometryDoesNotInventArea() {
        val original = NativeTableCornerShape(NativeFloatBounds(0f, 0f, .7f, 1.5f),
            NativeCornerRadii(1f, 1f, 1f, 0f), .1f)
        val moved = original.translated(5.25f, -2.5f)
        assertSame(original.outerRadii, moved.outerRadii)
        assertSame(original.innerRadii, moved.innerRadii)
        assertEquals(original.borderBox.translated(5.25f, -2.5f), moved.borderBox)
        assertEquals(original.paddingBox!!.translated(5.25f, -2.5f), moved.paddingBox)
        for ((x, y) in listOf(.1f to .1f, .35f to .75f, .05f to 1.45f))
            assertEquals(original.contains(x, y), moved.contains(x + 5.25f, y - 2.5f))
        val empty = NativeTableCornerShape(NativeFloatBounds(2f, 3f, 2f, 5f),
            NativeCornerRadii(8f, 8f, 8f, 0f), 0f)
        assertEquals(NativeCornerRadii(0f, 0f, 0f, 0f), empty.outerRadii)
        assertNull(empty.paddingBox)
        assertFalse(empty.contains(2f, 4f))
    }

    @Test fun maximumSourceRadiusAndLargeDensityNormalizeBeforeFloatConversion() {
        val limit = px(16777216f)
        val source = TableCornerRadii(limit, limit, limit, limit)
        val physical = nativeTableCornerRadii(source, Float.MAX_VALUE)
        assertTrue(physical.topLeft > Float.MAX_VALUE.toDouble())
        val shape = NativeTableCornerShape(NativeFloatBounds(0f, 0f, 6f, 4f), physical, .5f)
        shape.outerRadii.clockwise.forEach { assertEquals(2.0, it, 1e-12) }
        shape.innerRadii.clockwise.forEach { assertEquals(1.5, it, 1e-12) }
        assertThrows(IllegalArgumentException::class.java) { NativeCornerRadii(Float.NaN, 0f, 0f, 0f) }
        assertThrows(IllegalArgumentException::class.java) { NativeCornerRadii(-1f, 0f, 0f, 0f) }
        assertThrows(UnsupportedFloatLayout::class.java) { nativeTableCornerRadii(source, 0f) }
        assertThrows(UnsupportedFloatLayout::class.java) {
            NativeTableCornerShape(shape.borderBox, shape.outerRadii, Float.POSITIVE_INFINITY)
        }
        assertThrows(UnsupportedFloatLayout::class.java) { shape.translated(Float.POSITIVE_INFINITY, 0f) }
    }
}
