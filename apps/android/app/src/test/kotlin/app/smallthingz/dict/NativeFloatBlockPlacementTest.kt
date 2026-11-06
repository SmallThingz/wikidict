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
