package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativePositionedScrollportTest {
    private val zero = FloatMargins(0f, 0f, 0f, 0f)

    @Test fun absoluteLinesInsideBottomPaddingDoNotIncreaseNormalFlowHeight() {
        val padding = FloatMargins(0f, 0f, 25f, 0f)
        val layout = NativeFloatBounds(0f, 0f, 310f, 162f)
        val positioned = nativePositionedScrollportAllocation(310, 157f, layout, padding)
        assertEquals(310, positioned.viewport)
        assertEquals(182, positioned.height)
        assertEquals(182f, positioned.usedHeight, 0f)
        assertEquals(0f, positioned.overflow, 0f)
        assertFalse(positioned.verticalOverflow)
        assertFalse(positioned.leadingOverflow)

        // The older auto-height domain deliberately expands to its content bounds.
        val ordinary = nativeScrollportAllocation(310, 157f, layout, padding)
        assertEquals(187, ordinary.height)
        assertTrue(ordinary.verticalOverflow)
    }

    @Test fun anyPositiveVerticalOverflowIsReportedAgainstExactHeightBeforeCeiling() {
        val padding = FloatMargins(.25f, 0f, 24.5f, 0f)
        val boundary = NativeFloatBounds(0f, 0f, 310f, 181.625f)
        val fits = nativePositionedScrollportAllocation(310, 157.125f, boundary, padding)
        assertEquals(181.875f, fits.usedHeight, 0f)
        assertEquals(182, fits.height)
        assertFalse(fits.verticalOverflow)

        val epsilon = 1f / 1024f
        val below = nativePositionedScrollportAllocation(310, 157.125f,
            boundary.copy(bottom = boundary.bottom + epsilon), padding)
        assertTrue(below.verticalOverflow)
        assertEquals(fits.usedHeight, below.usedHeight, 0f)
        assertEquals(fits.height, below.height)
        val above = nativePositionedScrollportAllocation(310, 157.125f,
            boundary.copy(top = -padding.top - epsilon), padding)
        assertTrue(above.verticalOverflow)
        assertEquals(fits.height, above.height)

        val tinyPadding = 1f / 33554432f
        val preciseAllocation = nativePositionedScrollportAllocation(100, 1f,
            NativeFloatBounds(0f, 0f, 100f, 1f), FloatMargins(tinyPadding, 0f, 0f, 0f))
        assertEquals(1f, preciseAllocation.usedHeight, 0f)
        assertEquals(2, preciseAllocation.height)
        assertFalse(preciseAllocation.verticalOverflow)

        // Both Float sums round to 2, but the descendant extends beyond the exact used height.
        val justBelowOne = Float.fromBits(1f.toRawBits() - 1)
        val tinyOverflow = nativePositionedScrollportAllocation(100, justBelowOne,
            NativeFloatBounds(0f, 0f, 100f, 1f), FloatMargins(1f, 0f, 0f, 0f))
        assertEquals(2f, tinyOverflow.usedHeight, 0f)
        assertEquals(2, tinyOverflow.height)
        assertTrue(tinyOverflow.verticalOverflow)
    }

    @Test fun paddingOriginAndFractionalHorizontalRangeRemainPhysical() {
        val padding = FloatMargins(5f, 0f, 25f, 0f)
        // Content y=-2 maps to physical padding-box y=3 without moving normal flow.
        val layout = NativeFloatBounds(0f, -2f, 130.375f, 162f)
        val allocation = nativePositionedScrollportAllocation(100, 157f, layout, padding)
        assertEquals(0f, allocation.originX, 0f)
        assertEquals(5f, allocation.originY, 0f)
        assertEquals(3f, layout.top + allocation.originY, 0f)
        assertEquals(30.375f, allocation.overflow, 0f)
        assertEquals(187f, allocation.usedHeight, 0f)
        assertEquals(187, allocation.height)
        assertFalse(allocation.verticalOverflow)
        assertFalse(allocation.leadingOverflow)

        val leading = nativePositionedScrollportAllocation(100, 157f,
            layout.copy(left = -.125f), padding)
        assertTrue(leading.leadingOverflow)
        assertEquals(0f, leading.originX, 0f)
        assertEquals(allocation.overflow, leading.overflow, 0f)
        assertEquals(allocation.height, leading.height)

        val end = nativePositionedScrollbarMetrics(100f, allocation.overflow, allocation.overflow)
        assertEquals(100, end.extent)
        assertEquals(131, end.range)
        assertEquals(end.range - end.extent, end.offset)
        val middle = nativePositionedScrollbarMetrics(100f, allocation.overflow, allocation.overflow / 2f)
        assertEquals(16, middle.offset)
        assertEquals(end.range, middle.range)
        assertEquals(0, nativePositionedScrollbarMetrics(100f, allocation.overflow, 0f).offset)
        val noRange = nativePositionedScrollbarMetrics(100f, 0f, 0f)
        assertEquals(100, noRange.extent)
        assertEquals(noRange.extent, noRange.range)
        assertEquals(0, noRange.offset)
    }

    @Test fun emptyReportedAreaAddsNoLineAndInvalidNativeDomainRefuses() {
        val empty = NativeFloatBounds(0f, 0f, 0f, 0f)
        val allocation = nativePositionedScrollportAllocation(100, 0f, empty, zero)
        assertEquals(0, allocation.height)
        assertEquals(0f, allocation.usedHeight, 0f)
        assertEquals(0f, allocation.overflow, 0f)
        assertFalse(allocation.verticalOverflow)
        assertFalse(allocation.leadingOverflow)
        val padded = nativePositionedScrollportAllocation(100, 0f, empty,
            FloatMargins(0f, 0f, 25f, 0f))
        assertEquals(25, padded.height)
        assertEquals(0f, padded.overflow, 0f)
        assertFalse(padded.verticalOverflow)

        assertTrue(runCatching { nativePositionedScrollportAllocation(100, 0f, empty,
            FloatMargins(0f, 0f, 0f, 1f)) }.isFailure)
        assertTrue(runCatching { nativePositionedScrollportAllocation(100, Float.NaN, empty, zero) }.isFailure)
        assertTrue(runCatching { nativePositionedScrollportAllocation(100, -1f, empty, zero) }.isFailure)
        assertTrue(runCatching { nativePositionedScrollportAllocation(-1, 0f, empty, zero) }.isFailure)
        assertTrue(runCatching { nativePositionedScrollportAllocation(TablePixelLimit + 1, 0f, empty, zero) }.isFailure)
        assertTrue(runCatching { nativePositionedScrollportAllocation(100, TablePixelLimit.toFloat(), empty,
            FloatMargins(1f, 0f, 0f, 0f)) }.isFailure)
    }
}
