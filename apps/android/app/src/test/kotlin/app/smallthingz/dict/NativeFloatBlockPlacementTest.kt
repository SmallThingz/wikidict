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

    @Test fun ordinaryFixedMarginsUseContainingDirectionForSpaceAndOverflow() {
        val margins = FloatMargins(2f, 6f, 3f, 4f)
        for (width in listOf(60f, 140f)) {
            for (direction in TableContainingDirection.entries) {
                var calls = 0
                val placed = placeNativeFixedMarginTable(100f, 10f, emptyList(), margins, direction,
                    widthRule = NativeBlockWidth.FixedPx(width)) {
                    calls++
                    assertEquals(100f, it.containingWidth, 0f)
                    assertEquals(width, it.requestedWidth!!, 0f)
                    NativeBlockMeasure(width, width, 20f)
                }
                val left = if (direction == TableContainingDirection.Ltr) 4f else 94f - width
                assertEquals(1, calls)
                assertEquals(NativeFloatBounds(left, 12f, left + width, 32f), placed.content)
                assertEquals(NativeFloatBounds(left - 4f, 10f, left + width + 6f, 35f), placed.outer)
            }
            // The wide placement remains physical right, independently of grid or containing direction.
            val floating = placeNativeFloatingTable(100f, 10f, emptyList(), TableFloatSide.Right,
                margins, NativeBlockWidth.FixedPx(width), pixelAligned = false) { NativeBlockMeasure(width, width, 20f) }
            assertEquals(NativeFloatBounds(94f - width, 12f, 94f, 32f), floating.content)
            assertEquals(NativeFloatBounds(90f - width, 10f, 100f, 35f), floating.outer)
        }
    }

    @Test fun fixedMarginPlacementRetainsFractionalBorderOriginsAndOneMarginQuartet() {
        val margins = FloatMargins(.125f, .625f, .875f, .375f)
        for (direction in TableContainingDirection.entries) {
            val placed = placeNativeFixedMarginTable(100.75f, .5f, emptyList(), margins, direction) {
                NativeBlockMeasure(60.25f, 60.25f, 30.25f)
            }
            val left = if (direction == TableContainingDirection.Ltr) .375f else 39.875f
            assertEquals(NativeFloatBounds(left, .625f, left + 60.25f, 30.875f), placed.content)
            assertEquals(left - .375f, placed.outer.left, 0f)
            assertEquals(61.25f, placed.outer.width, 0f)
            assertEquals(.5f, placed.outer.top, 0f)
            assertEquals(31.75f, placed.outer.bottom, 0f)
        }
        val floating = placeNativeFloatingTable(100.75f, .5f, emptyList(), TableFloatSide.Right,
            margins, NativeBlockWidth.Auto, pixelAligned = false) { NativeBlockMeasure(60.25f, 60.25f, 30.25f) }
        assertEquals(NativeFloatBounds(39.875f, .625f, 100.125f, 30.875f), floating.content)
        assertEquals(NativeFloatBounds(39.5f, .5f, 100.75f, 31.75f), floating.outer)
    }

    @Test fun ordinaryFixedMarginsUseTheWholeHeightFreeIntervalWithoutChangingContainingBasis() {
        val occupied = listOf(
            NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 40f, 80f)),
            NativeFloatExclusion(TableFloatSide.Right, NativeFloatBounds(170f, 0f, 200f, 90f)))
        val margins = FloatMargins(2f, 6f, 3f, 4f)
        for (direction in TableContainingDirection.entries) {
            val placed = placeNativeFixedMarginTable(200f, 5f, occupied, margins, direction) {
                assertEquals(200f, it.containingWidth, 0f)
                assertNull(it.requestedWidth)
                NativeBlockMeasure(60f, 60f, 20f)
            }
            val left = if (direction == TableContainingDirection.Ltr) 44f else 104f
            assertEquals(NativeFloatBounds(left, 7f, left + 60f, 27f), placed.content)
            assertEquals(NativeFloatBounds(left - 4f, 5f, left + 66f, 30f), placed.outer)
        }
        val floating = placeNativeFloatingTable(200f, 5f, occupied, TableFloatSide.Right,
            margins, NativeBlockWidth.Auto, pixelAligned = false) { NativeBlockMeasure(60f, 60f, 20f) }
        assertEquals(NativeFloatBounds(104f, 7f, 164f, 27f), floating.content)
        assertEquals(NativeFloatBounds(100f, 5f, 170f, 30f), floating.outer)
    }

    @Test fun ordinaryFixedMarginsMoveBelowAFloatThatIntersectsOnlyTheLowerBody() {
        val occupied = listOf(NativeFloatExclusion(TableFloatSide.Left,
            NativeFloatBounds(0f, 50f, 150f, 100f)))
        for (direction in TableContainingDirection.entries) {
            val placed = placeNativeFixedMarginTable(200f, 0f, occupied,
                FloatMargins(2f, 6f, 3f, 4f), direction) { NativeBlockMeasure(60f, 60f, 80f) }
            val left = if (direction == TableContainingDirection.Ltr) 4f else 134f
            assertEquals(NativeFloatBounds(left, 100f, left + 60f, 180f), placed.content)
            assertEquals(98f, placed.outer.top, 0f)
            assertEquals(183f, placed.outer.bottom, 0f)
        }
    }

    @Test fun ordinaryFixedMarginClearUsesPhysicalSidesAndClearsAtTheBorderEdge() {
        val occupied = listOf(
            NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 60f, 60f)),
            NativeFloatExclusion(TableFloatSide.Right, NativeFloatBounds(170f, 0f, 200f, 90f)))
        val margins = FloatMargins(15f, 6f, 7f, 4f)
        for ((clear, borderTop) in listOf(FigureClear.None to 25f, FigureClear.Left to 60f,
            FigureClear.Right to 90f, FigureClear.Both to 90f)) {
            val placed = placeNativeFixedMarginTable(200f, 10f, occupied, margins,
                TableContainingDirection.Ltr, clear = clear) { NativeBlockMeasure(60f, 60f, 10f) }
            assertEquals(if (clear == FigureClear.None) 64f else 4f, placed.content.left, 0f)
            assertEquals(borderTop, placed.content.top, 0f)
            assertEquals(borderTop - 15f, placed.outer.top, 0f)
            assertEquals(borderTop + 17f, placed.outer.bottom, 0f)
        }
        val alreadyBelow = placeNativeFixedMarginTable(200f, 10f, occupied, margins.copy(top = 100f),
            TableContainingDirection.Ltr, clear = FigureClear.Left) { NativeBlockMeasure(60f, 60f, 10f) }
        assertEquals(110f, alreadyBelow.content.top, 0f)
        assertEquals(10f, alreadyBelow.outer.top, 0f)
        assertEquals(127f, alreadyBelow.outer.bottom, 0f)
    }

    @Test fun responsiveClearFeedsTheRealFixedWidthAllocatorWithoutShrinkingOrMirroringItsFloat() {
        val occupied = listOf(
            NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 50.5f, 80.25f)),
            NativeFloatExclusion(TableFloatSide.Right, NativeFloatBounds(170f, 0f, 200f, 30.5f)))
        val margins = FloatMargins(0f, 6.75f, 0f, 4.25f)
        fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
        val sourceStyle = TableStyle(margins = StyleEdges(px(0f), px(6.75f), px(0f), px(4.25f)),
            width = StyleWidth(StyleWidthUnit.Px, 100.25f), floatSide = TableFloatSide.Right, clear = FigureClear.Right)
        val source = Table(emptyList(), listOf(listOf(Cell(listOf(Span("link", "Prefix", "Target")), false, 1, 1))),
            style = sourceStyle, floatViewport = TableFloatViewport(639, TableContainingDirection.Ltr,
                TableContainingDirection.Rtl, "th", FigureClear.Both))
        fun solve(table: Table, viewport: Double): NativeFloatingTablePlacement {
            val effective = table.effectiveFloatStyle(viewport)!!
            val width = effective.width!!
            assertEquals(StyleWidthUnit.Px, width.unit)
            var calls = 0
            val measure: (NativeBlockMeasureRequest) -> NativeBlockMeasure = { request ->
                calls++
                assertEquals(200f, request.containingWidth, 0f)
                assertEquals(189f, request.availableWidth, 0f)
                assertEquals(width.value, request.requestedWidth!!, 0f)
                NativeBlockMeasure(width.value, 10f, 20.25f)
            }
            val placed = if (effective.floatSide != null) {
                placeNativeFloatingTable(200f, tableClearanceY(3.5f, effective.clear, occupied), occupied,
                    effective.floatSide, margins, NativeBlockWidth.FixedPx(width.value), pixelAligned = false, measure = measure)
            } else placeNativeFixedMarginTable(200f, 3.5f, occupied, margins,
                table.floatViewport!!.containingDirection, NativeBlockWidth.FixedPx(width.value), effective.clear, measure)
            assertEquals("A fixed request is measured once even when it must move below both blockers", 1, calls)
            assertEquals(width.value, placed.content.width, 0f)
            assertEquals(width.value + 11f, placed.outer.width, 0f)
            assertEquals(20.25f, placed.content.height, 0f)
            assertSame(source.rows, table.rows)
            return placed
        }
        for (direction in TableContainingDirection.entries) {
            val table = source.copy(floatViewport = source.floatViewport!!.copy(containingDirection = direction))
            val wide = solve(table, 639.5)
            assertEquals(NativeFloatBounds(93f, 30.5f, 193.25f, 50.75f), wide.content)
            val narrow = solve(table, 639.0)
            val narrowLeft = if (direction == TableContainingDirection.Ltr) 4.25f else 93f
            assertEquals(NativeFloatBounds(narrowLeft, 80.25f, narrowLeft + 100.25f, 100.5f), narrow.content)
            val absent = solve(table.copy(floatViewport = table.floatViewport!!.copy(narrowClear = null)), 639.0)
            assertEquals(if (direction == TableContainingDirection.Ltr) 54.75f else 93f, absent.content.left, 0f)
            assertEquals(30.5f, absent.content.top, 0f)
            val none = solve(table.copy(floatViewport = table.floatViewport!!.copy(narrowClear = FigureClear.None)), 639.0)
            assertEquals(if (direction == TableContainingDirection.Ltr) 54.75f else 63f, none.content.left, 0f)
            assertEquals(3.5f, none.content.top, 0f)
            val overwide = table.copy(style = sourceStyle.copy(width = StyleWidth(StyleWidthUnit.Px, 240.25f)),
                floatViewport = table.floatViewport!!.copy(narrowClear = FigureClear.None))
            val overflow = solve(overwide, 639.0)
            assertEquals(if (direction == TableContainingDirection.Ltr) 4.25f else -47f, overflow.content.left, 0f)
            assertEquals(80.25f, overflow.content.top, 0f)
            assertEquals(-47f, solve(overwide, 639.5).content.left, 0f)
        }
        assertEquals(FigureClear.Right, sourceStyle.clear); assertEquals(TableFloatSide.Right, sourceStyle.floatSide)
    }

    @Test fun disclosureFloatFitsOriginalFractionalWidthAndKeepsPhysicalExclusion() {
        val intrinsic = ContainerWidths(20.25f, 43.75f)
        assertEquals(20.25f, nativeDisclosureWidth(0f, intrinsic), 0f)
        assertEquals(25.375f, nativeDisclosureWidth(25.375f, intrinsic), 0f)
        assertEquals(43.75f, nativeDisclosureWidth(100.75f, intrinsic), 0f)
        assertEquals(0f, nativeDisclosureWidth(0f, ContainerWidths(0f, 0f)), 0f)
        assertThrows(UnsupportedFloatLayout::class.java) { nativeDisclosureWidth(Float.NaN, intrinsic) }
        val blocker = NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 80.5f, 12.25f))
        for (side in TableFloatSide.entries) {
            var calls = 0
            val placed = placeNativeFloatingTable(100.75f, 0f, listOf(blocker), side, zero,
                NativeBlockWidth.FixedPx(nativeDisclosureWidth(100.75f, intrinsic)), pixelAligned = false) { request ->
                calls++
                assertEquals(100.75f, request.containingWidth, 0f)
                assertEquals(43.75f, request.requestedWidth!!, 0f)
                NativeBlockMeasure(43.75f, 20.25f, 8.5f)
            }
            assertEquals(1, calls)
            assertEquals(if (side == TableFloatSide.Left) 0f else 57f, placed.content.left, 0f)
            assertEquals(12.25f, placed.content.top, 0f)
            assertEquals(43.75f, placed.outer.width, 0f)
            assertEquals(8.5f, placed.outer.height, 0f)
        }
        // Returning to the original width restores the original allocation, without state.
        assertEquals(25.375f, nativeDisclosureWidth(25.375f, intrinsic), 0f)
    }

}
