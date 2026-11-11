package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativeFloatBlockPlacementTest {
    private val zero = FloatMargins(0f, 0f, 0f, 0f)
    @Test fun physicalSidesAndOneMarginBoxPreserveOriginalPercentageBasis() {
        for (side in TableFloatSide.entries) {
            var request: NativeBlockMeasureRequest? = null
            val placed = placeNativeFloatingTable(400f, 0f, emptyList(), side, FloatMargins(2f, 3f, 4f, 20f),
                NativeBlockWidth.Percent(25f)) {
                request = it; NativeBlockMeasure(it.requestedWidth!!, it.requestedWidth, 30f)
            }
            assertEquals(400f, request!!.containingWidth, 0f)
            assertEquals(100f, request!!.requestedWidth!!, 0f)
            assertEquals(123f, placed.outer.width, 0f)
            assertEquals(36f, placed.outer.height, 0f)
            assertEquals(100f, placed.content.width, 0f)
            assertEquals(20f, placed.content.left - placed.outer.left, 0f)
            assertEquals(if (side == TableFloatSide.Left) 0f else 277f, placed.outer.left, 0f)
        }
    }

    @Test fun laterFloatCannotRiseAboveEarlierSourceFloatAndFixedWidthNeverNarrows() {
        val occupied = listOf(NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 40f, 180f, 100f)))
        val placed = placeNativeFloatingTable(240f, 0f, occupied, TableFloatSide.Right, zero,
            NativeBlockWidth.FixedPx(100f)) {
            assertEquals(100f, it.requestedWidth!!, 0f)
            NativeBlockMeasure(100f, 100f, 30f)
        }
        assertEquals(100f, placed.outer.top, 0f)
        assertEquals(140f, placed.outer.left, 0f)
    }

    @Test fun exactWrapperMarginsRetainFractionalOriginsAndOriginalWidthBasis() {
        val margins = FloatMargins(.125f, .625f, .875f, .375f)
        for (side in TableFloatSide.entries) {
            var calls = 0
            val placed = placeNativeFloatingTable(400f, .5f, emptyList(), side, margins,
                NativeBlockWidth.Percent(25f), pixelAligned = false) {
                calls++
                assertEquals(400f, it.containingWidth, 0f)
                assertEquals(100f, it.requestedWidth!!, 0f)
                NativeBlockMeasure(100f, 100f, 30.25f)
            }
            assertEquals(1, calls)
            assertEquals(101f, placed.outer.width, 0f)
            assertEquals(31.25f, placed.outer.height, 0f)
            assertEquals(.625f, placed.content.top, 0f)
            assertEquals(.375f, placed.content.left - placed.outer.left, 0f)
            assertEquals(if (side == TableFloatSide.Left) 0f else 299f, placed.outer.left, 0f)
        }
        val normal = placeNativeClearedTable(400f, .5f, emptyList(), FigureClear.None,
            margins.copy(top = 0f, bottom = 0f), NativeBlockWidth.Percent(25f), pixelAligned = false) {
            assertEquals(100f, it.requestedWidth!!, 0f)
            NativeBlockMeasure(100f, 100f, 30.25f)
        }
        assertEquals(.375f, normal.content.left, 0f)
        assertEquals(.5f, normal.content.top, 0f)
        assertEquals(30.75f, normal.outer.bottom, 0f)
    }

    @Test fun zeroContainingWidthRetainsRealZeroAndAuthoredOverflowWithoutRemeasurement() {
        var calls = 0
        val zeroBox = placeNativeFloatBlock(0f, 0f, emptyList(), NativeBlockWidth.FixedPx(0f)) {
            calls++
            assertEquals(0f, it.availableWidth, 0f)
            assertEquals(0f, it.requestedWidth!!, 0f)
            NativeBlockMeasure(0f, 0f, 0f)
        }
        assertEquals(1, calls)
        assertEquals(NativeFloatBounds(0f, 0f, 0f, 0f), zeroBox.bounds)
        val overflow = placeNativeFloatingTable(0f, .5f, emptyList(), TableFloatSide.Right,
            FloatMargins(0f, .25f, 0f, .75f), NativeBlockWidth.FixedPx(20f), pixelAligned = false) {
            assertEquals(0f, it.containingWidth, 0f)
            assertEquals(20f, it.requestedWidth!!, 0f)
            NativeBlockMeasure(20f, 20f, 10f)
        }
        assertEquals(-21f, overflow.outer.left, 0f)
        assertEquals(0f, overflow.outer.right, 0f)
        assertEquals(-20.25f, overflow.content.left, 0f)
        assertEquals(.5f, overflow.outer.top, 0f)
    }

    @Test fun wholeHeightCollisionAndOversizeMarginsAreNotSilentlyClipped() {
        val occupied = listOf(NativeFloatExclusion(TableFloatSide.Right, NativeFloatBounds(160f, 50f, 240f, 100f)))
        val placed = placeNativeFloatingTable(240f, 0f, occupied, TableFloatSide.Left, zero,
            NativeBlockWidth.FixedPx(200f)) { NativeBlockMeasure(200f, 200f, 80f) }
        assertEquals(100f, placed.outer.top, 0f)
        assertThrows(UnsupportedFloatLayout::class.java) {
            placeNativeFloatingTable(240f, 0f, emptyList(), TableFloatSide.Right, FloatMargins(0f, Float.MAX_VALUE, 0f, Float.MAX_VALUE),
                NativeBlockWidth.FixedPx(100f)) { NativeBlockMeasure(100f, 100f, 30f) }
        }
    }
}
