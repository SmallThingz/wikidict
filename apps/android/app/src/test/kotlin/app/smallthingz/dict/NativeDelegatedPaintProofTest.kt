package app.smallthingz.dict

import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NativeDelegatedPaintProofTest {
    private val generation = Any()
    private val owners = listOf(Any(), Any())
    private fun box(left: Float, top: Float, right: Float, bottom: Float) = NativeFloatBounds(left, top, right, bottom)
    private val table = box(40f, 0f, 240f, 600f)
    private fun cells() = owners.mapIndexed { index, owner ->
        val top = index * 300f
        val cell = box(40f, top, 240f, top + 300f)
        val surface = box(44f, top + 4f, 236f, top + 296f)
        NativeDelegatedMeasuredCell(owner, generation, cell, surface,
            listOf(NativeDelegatedInputAncestor(cell, false), NativeDelegatedInputAncestor(table, false)),
            ink = listOf(box(45f, top + 5f, 235f, top + 295f)),
            deferredInk = listOf(box(46f, top + 6f, 234f, top + 268f)),
            input = listOf(box(48f, top + 8f, 232f, top + 266f)))
    }
    private fun surroundings(ink: List<NativeFloatBounds>? = emptyList(), input: List<NativeFloatBounds>? = emptyList()) =
        NativeDelegatedSurroundings(generation, table, ink, input)
    private fun permitted(cells: List<NativeDelegatedMeasuredCell> = cells(), surroundings: NativeDelegatedSurroundings = surroundings()) =
        nativeDelegatedPaintDecision(surroundings, cells, owners) is NativeDelegatedPaintDecision.Permitted

    @Test fun twoRealCellOwnersRetainTheSameSourceOrderWithoutAnotherGraph() {
        assertTrue(permitted())
        assertTrue(!permitted(cells().reversed()))
        assertTrue(!permitted(cells().map { it.copy(generation = Any()) }))
        assertTrue(!permitted(listOf(cells()[0], cells()[1].copy(owner = owners[0]))))
    }

    @Test fun unknownOrOverlappingPaintCannotBeApprovedByCellContainment() {
        assertTrue(!permitted(surroundings = surroundings(ink = null)))
        assertTrue(!permitted(surroundings = surroundings(ink = listOf(box(90f, 30f, 100f, 40f)))))
        assertTrue(permitted(surroundings = surroundings(ink = listOf(box(0f, 0f, 40f, 600f)))))
    }

    @Test fun transparentPhysicalInputOverlapStillRefuses() {
        // Outside the authored action, but inside the actual AndroidView's Compose hit rectangle.
        assertTrue(!permitted(surroundings = surroundings(input = listOf(box(44f, 280f, 45f, 290f)))))
        assertTrue(!permitted(surroundings = surroundings(input = null)))
    }

    @Test fun completeFocusAndAfterInkMustFitTheOriginalPhysicalOwner() {
        val initial = cells()
        assertTrue(!permitted(initial.toMutableList().also {
            it[0] = it[0].copy(deferredInk = it[0].deferredInk + box(42f, 4f, 48f, 12f))
        }))
        assertTrue(!permitted(initial.toMutableList().also {
            it[0] = it[0].copy(physicalSurface = box(38f, 4f, 236f, 296f))
        }))
    }

    @Test fun actualClipIsPreservedButUnclippedOutOfBoundsTraversalIsNotAssumed() {
        val clipped = cells().map { it.copy(realInputAncestors = it.realInputAncestors +
            NativeDelegatedInputAncestor(box(0f, 100f, 300f, 400f), true)) }
        assertTrue(permitted(clipped))
        assertTrue(!permitted(cells().map { it.copy(realInputAncestors = listOf(
            NativeDelegatedInputAncestor(box(40f, 0f, 200f, 600f), false))) }))
    }

    @Test fun resizeAndCellOverlapRequireNewMeasuredProof() {
        assertTrue(!permitted(surroundings = surroundings().copy(allocation = box(40f, 0f, 180f, 600f))))
        assertTrue(!permitted(cells().toMutableList().also {
            it[1] = it[1].copy(cell = box(40f, 290f, 240f, 600f))
        }))
        assertTrue(permitted())
    }

    @Test fun ordinaryTouchNeedsBothAxesOfTheActualSurfaceAndEveryAncestor() {
        val base = cells().map { it.copy(minimumTouchWidth = 48f, minimumTouchHeight = 48f) }
        assertTrue(permitted(base))
        assertTrue(!permitted(base.map { it.copy(minimumTouchWidth = 193f) }))
        assertTrue(!permitted(base.map { it.copy(realInputAncestors = listOf(
            NativeDelegatedInputAncestor(box(0f, 0f, 300f, 47f), false))) }))
        // The clipped visible strip is not the physical size used for minimum-target expansion.
        assertTrue(permitted(base.map { it.copy(realInputAncestors = listOf(
            NativeDelegatedInputAncestor(box(40f, 20f, 240f, 40f), true)) + it.realInputAncestors) }))
        assertTrue(!permitted(base.map { it.copy(minimumTouchWidth = Float.NaN) }))
    }

    @Test fun deferredMediaCannotCrossOrdinaryFocusOrSelectionEvenWithinOneOwner() {
        val base = cells()
        assertTrue(!permitted(base.toMutableList().also {
            it[0] = it[0].copy(ordinaryStateInk = listOf(box(80f, 40f, 82f, 60f)))
        }))
        assertTrue(permitted(base.toMutableList().also {
            it[0] = it[0].copy(ordinaryStateInk = listOf(box(80f, 270f, 82f, 290f)))
        }))
    }

    @Test fun defaultFocusStrokeAloneCannotCrossAnotherPaintPhase() {
        val media = box(80f, 40f, 120f, 80f)
        for (density in listOf(1f, 2f)) for (missing in listOf(false, true)) {
            val outset = if (missing) 2f * density else density / 2f
            val ink = nativeDelegatedDefaultFocusInk(media, density, missing)
            assertEquals(box(80f - outset, 40f - outset, 120f + outset, 80f + outset), ink)
            val strokeOnly = box(120f + outset / 4f, 50f, 120f + outset / 2f, 60f)
            val initial = cells().toMutableList()
            initial[0] = initial[0].copy(deferredInk = listOf(media))
            assertTrue(permitted(initial, surroundings(ink = listOf(strokeOnly))))
            initial[0] = initial[0].copy(deferredInk = listOf(media, ink))
            assertTrue(!permitted(initial, surroundings(ink = listOf(strokeOnly))))
            assertTrue(!permitted(initial.toMutableList().also {
                it[0] = it[0].copy(ordinaryStateInk = listOf(strokeOnly))
            }))
            assertTrue(permitted(initial, surroundings(ink = listOf(
                box(120f + outset, 50f, 121f + outset, 60f)))))
        }
    }

    private fun sourceTable() = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1,
        blocks = listOf(Block("paragraph", 0, listOf(Span("text", "owner"))))))))

    @Test fun permanentRefusalConvergesAndOnlyRealSourceWidthOrResourceChangesRetry() {
        var invalidations = 0
        val owner = NativeDelegatedTableOwner(sourceTable()) { invalidations++ }
        owner.begin(listOf("same source"), 200)
        owner.refuse("permanent overlap")
        owner.composedFallback(true)
        repeat(20) {
            owner.begin(listOf("same source"), 200)
            assertEquals("permanent overlap", owner.fallbackReason)
            assertTrue(owner.permitsCellContent())
            assertTrue(!owner.permitsOriginalOwners())
        }
        assertEquals(1, invalidations)
        owner.begin(listOf("same source"), 201)
        assertNull(owner.fallbackReason)
        owner.refuse("the prior fallback has no native publication")
        assertNull(owner.fallbackReason)
        assertTrue(owner.permitsCellContent())
        assertTrue(!owner.permitsOriginalOwners())
        owner.composedFallback(false)
        owner.refuse("new measured overlap")
        assertEquals("new measured overlap", owner.fallbackReason)
        owner.composedFallback(true)
        owner.prepared(0, "loading")
        owner.prepared(0, "ready")
        assertNull(owner.fallbackReason)
        owner.composedFallback(false)
        owner.refuse("still unsupported")
        owner.begin(listOf("different source"), 201)
        assertNull(owner.fallbackReason)
    }

    @Test fun sourceIdentityDistinguishesAnEqualReplacementFromTheSameTableReflow() {
        val first = sourceTable()
        val equalReplacement = sourceTable()
        assertEquals(first, equalReplacement)
        assertEquals(NativeDelegatedTableIdentity(first), NativeDelegatedTableIdentity(first))
        assertTrue(NativeDelegatedTableIdentity(first) != NativeDelegatedTableIdentity(equalReplacement))
    }

    @Test fun firstRefusalSurvivesFallbackTeardownUntilARealRevision() {
        val owner = NativeDelegatedTableOwner(sourceTable()) { }
        owner.begin("source", 200)
        val first = "stage=paint/input proof; ink=[1,2,3,4]; clip=[0,0,200,300]"
        owner.refuse("original overlap", first)
        owner.composedFallback(true)
        repeat(3) {
            owner.begin("source", 200)
            owner.refuse("The original table cell did not publish current native geometry", "secondary missing binding")
            assertEquals("original overlap", owner.fallbackReason)
            assertEquals(first, owner.refusalEvidence)
            assertTrue(!owner.permitsOriginalOwners())
        }
        owner.begin("source", 201)
        assertNull(owner.fallbackReason)
        assertNull(owner.refusalEvidence)
        owner.refuse("prior fallback is still composed", "must not become the next failure")
        assertNull(owner.refusalEvidence)
        owner.composedFallback(false)
        owner.refuse("new snapshot failure", "stage=cell[0] deferred envelope is empty")
        assertEquals("stage=cell[0] deferred envelope is empty", owner.refusalEvidence)
        owner.prepared(0, "loading")
        owner.prepared(0, "ready")
        assertNull(owner.fallbackReason)
        assertNull(owner.refusalEvidence)
    }
}
