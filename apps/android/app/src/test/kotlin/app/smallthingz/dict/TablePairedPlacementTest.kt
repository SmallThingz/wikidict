package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class TablePairedPlacementTest {
    private val blockers = listOf(
        NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 60f, 40f)),
        NativeFloatExclusion(TableFloatSide.Right, NativeFloatBounds(160f, 25f, 200f, 70f)),
    )
    private val margins = FloatMargins(0f, 6f, 0f, 4f)

    @Test fun changedHeightRefitsTheWholeFloatIntervalWithOriginalPercentageBasis() {
        val requests = mutableListOf<NativeBlockMeasureRequest>()
        val placed = placeNativeFixedMarginTable(200f, 0f, blockers, margins,
            TableContainingDirection.Ltr) { request ->
            requests += request
            val width = maxOf(40f, minOf(170f, request.availableWidth))
            NativeBlockMeasure(width, 40f, if (width >= 140f) 20f else 50f)
        }
        assertEquals(listOf(200f, 140f, 100f), requests.map { it.assignedWidth })
        assertEquals(listOf(190f, 130f, 90f), requests.map { it.availableWidth })
        assertTrue(requests.all { it.containingWidth == 200f && it.requestedWidth == null })
        assertEquals(NativeFloatBounds(64f, 0f, 154f, 50f), placed.content)
        assertEquals(NativeFloatBounds(60f, 0f, 160f, 50f), placed.outer)
    }

    @Test fun intrinsicFloorMovesBelowOnlyTheBlockingFloatThenReflows() {
        val requests = mutableListOf<NativeBlockMeasureRequest>()
        val placed = placeNativeFixedMarginTable(200f, 0f, blockers, margins,
            TableContainingDirection.Ltr) { request ->
            requests += request
            val width = maxOf(120f, minOf(170f, request.availableWidth))
            NativeBlockMeasure(width, 120f, if (width >= 140f) 20f else 50f)
        }
        assertEquals(NativeFloatBounds(4f, 40f, 154f, 60f), placed.content)
        assertTrue(requests.any { it.assignedWidth == 140f })
        assertEquals(160f, requests.last().assignedWidth, 0f)
        assertEquals(200f, requests.last().containingWidth, 0f)
        assertTrue(placed.content.top < blockers.last().outer.bottom)
    }

    @Test fun fullIntervalSurvivesMarginClampAndDirectionOwnsSignedOverflow() {
        val edges = FloatMargins(0f, 6f, 0f, 4f)
        val requests = mutableListOf<NativeBlockMeasureRequest>()
        val rtl = placeNativeFixedMarginTable(5f, 0f, emptyList(), edges,
            TableContainingDirection.Rtl) { request ->
            requests += request
            NativeBlockMeasure(12f, 12f, 7f)
        }
        assertEquals(5f, requests.single().assignedWidth, 0f)
        assertEquals(0f, requests.single().availableWidth, 0f)
        assertEquals(NativeFloatBounds(-13f, 0f, -1f, 7f), rtl.content)
        val ltr = placeNativeFixedMarginTable(5f, 0f, emptyList(), edges,
            TableContainingDirection.Ltr) { NativeBlockMeasure(12f, 12f, 7f) }
        assertEquals(NativeFloatBounds(4f, 0f, 16f, 7f), ltr.content)
    }

    @Test fun clearAppliesBeforeIntrinsicFittingWithoutChangingContainingWidth() {
        val requests = mutableListOf<NativeBlockMeasureRequest>()
        val placed = placeNativeFixedMarginTable(200f, 0f, blockers, margins,
            TableContainingDirection.Rtl, clear = FigureClear.Both) { request ->
            requests += request
            NativeBlockMeasure(80f, 40f, 10f)
        }
        assertEquals(1, requests.size)
        assertEquals(200f, requests.single().assignedWidth, 0f)
        assertEquals(NativeFloatBounds(114f, 70f, 194f, 80f), placed.content)
    }
}
