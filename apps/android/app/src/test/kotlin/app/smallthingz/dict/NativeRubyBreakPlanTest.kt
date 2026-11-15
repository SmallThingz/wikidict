package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Synthetic scalar inputs for the native shaping interface. These controls establish
 * neither native measurements nor Unicode break-opportunity discovery. */
class NativeRubyBreakPlanTest {
    private fun reading(id: Int, first: Int, count: Int, vararg cuts: Pair<Int, Float>) =
        NativeRubyReadingBreak(id, first, count, cuts.last().first,
            cuts.map { NativeRubyReadingCut(it.first, it.second) })

    private fun width(reading: NativeRubyReadingBreak, slice: NativeRubySourceSlice): Float =
        reading.opportunities.single { it.offset == slice.to }.advance -
            reading.opportunities.single { it.offset == slice.from }.advance

    /** A single base with parallel whole-base readings is the closed max-width case. */
    private fun singleBaseWidth(readings: List<NativeRubyReadingBreak>):
        (NativeRubyBaseCut, NativeRubyBaseCut, Map<Int, NativeRubySourceSlice>) -> Float = { from, to, slices ->
        maxOf(to.advance - from.advance, slices.entries.maxOfOrNull { (id, slice) ->
            width(readings.single { it.id == id }, slice)
        } ?: 0f)
    }

    @Test fun unequalUtf16CutsPreserveCompleteIndependentSourcesAndReadingIds() {
        val baseText = "\u7532\ud83d\ude80e\u0301 \u4e59"
        val readingText = "read more later"
        assertEquals(7, baseText.length)
        assertEquals(15, readingText.length)
        val cuts = listOf(NativeRubyBaseCut(0, 0, 0f), NativeRubyBaseCut(0, 6, 40f), NativeRubyBaseCut(1, 0, 70f))
        val annotation = reading(37, 0, 1, 0 to 0f, 5 to 20f, 10 to 40f, 15 to 70f)
        val plan = nativeRubyBreakPlan(1, cuts, listOf(annotation), 45f, singleBaseWidth(listOf(annotation)))
        assertEquals(2, plan.size)
        assertSame(cuts[1], plan[0].baseTo)
        assertEquals(NativeRubySourceSlice(0, 10), plan[0].readings[37])
        assertEquals(NativeRubySourceSlice(10, 15), plan[1].readings[37])
        assertEquals(listOf(40f, 30f), plan.map { it.width })
        fun offset(cut: NativeRubyBaseCut) = if (cut.baseIndex == 1) baseText.length else cut.offset
        assertEquals(baseText, plan.joinToString("") { baseText.substring(offset(it.baseFrom), offset(it.baseTo)) })
        assertEquals(readingText, plan.joinToString("") { it.readings.getValue(37).let { span ->
            readingText.substring(span.from, span.to)
        } })
        assertEquals(setOf(37), plan.flatMap { it.readings.keys }.toSet())
        assertEquals(6, plan.first().baseTo.offset) // Never equated to the reading's offset10.
    }

    @Test fun connectedComponentsDoNotInventAnOrdinaryBreakBetweenBaseOwners() {
        val noReadings = emptyList<NativeRubyReadingBreak>()
        assertEquals(listOf(NativeRubyBaseRange(0, 1), NativeRubyBaseRange(1, 1)),
            nativeRubyConnectedBaseRanges(2, noReadings))
        // Two owners can still form one unbreakable ordinary word (inter + national).
        val intact = listOf(NativeRubyBaseCut(0, 0, 0f), NativeRubyBaseCut(2, 0, 100f))
        val measure = { from: NativeRubyBaseCut, to: NativeRubyBaseCut, _: Map<Int, NativeRubySourceSlice> ->
            to.advance - from.advance }
        val narrow = nativeRubyBreakPlan(2, intact, noReadings, 40f, measure)
        assertEquals(1, narrow.size)
        assertEquals(100f, narrow.single().width, 0f)
        val legalBoundary = listOf(intact.first(), NativeRubyBaseCut(1, 0, 40f), intact.last())
        val split = nativeRubyBreakPlan(2, legalBoundary, noReadings, 40f, measure)
        assertEquals(listOf(40f, 60f), split.map { it.width })
        assertEquals(1, nativeRubyBreakPlan(2, legalBoundary, noReadings, 100f, measure).size)
        assertSame(intact.last(), narrow.single().baseTo)
    }

    @Test fun overlappingCoverageKeepsPartialAnnotationsOnTheirOwnBases() {
        val annotations = listOf(reading(11, 0, 2, 0 to 0f, 4 to 50f, 8 to 100f),
            reading(22, 1, 2, 0 to 0f, 3 to 60f, 6 to 100f), reading(33, 3, 1, 0 to 0f, 2 to 20f))
        assertEquals(listOf(NativeRubyBaseRange(0, 3), NativeRubyBaseRange(3, 1)),
            nativeRubyConnectedBaseRanges(4, annotations))
        val cuts = (0..4).map { NativeRubyBaseCut(it, 0, it * 10f) }
        val measure = { from: NativeRubyBaseCut, to: NativeRubyBaseCut, slices: Map<Int, NativeRubySourceSlice> ->
            val constraints = slices.map { (id, slice) ->
                val reading = annotations.single { it.id == id }
                val first = maxOf(from.baseIndex, reading.baseStart)
                val end = minOf(to.baseIndex, reading.baseStart + reading.baseCount)
                NativeRubyWidthConstraint(first - from.baseIndex, end - first, width(reading, slice))
            }
            nativeRubyColumnWidths(List(to.baseIndex - from.baseIndex) { 10f },
                List(to.baseIndex - from.baseIndex) { 0f }, constraints).sum()
        }
        val plan = nativeRubyBreakPlan(4, cuts, annotations, 50f, measure)
        assertEquals(listOf(1, 2, 3, 4), plan.map { it.baseTo.baseIndex })
        assertEquals(mapOf(11 to NativeRubySourceSlice(0, 4)), plan[0].readings)
        assertEquals(mapOf(11 to NativeRubySourceSlice(4, 8), 22 to NativeRubySourceSlice(0, 3)), plan[1].readings)
        assertEquals(mapOf(22 to NativeRubySourceSlice(3, 6)), plan[2].readings)
        assertEquals(mapOf(33 to NativeRubySourceSlice(0, 2)), plan[3].readings)
        assertEquals(listOf(50f, 60f, 40f, 20f), plan.map { it.width })
        assertFalse(plan[0].readings.containsKey(22))
        assertFalse(plan[2].readings.containsKey(11))
        val wide = nativeRubyBreakPlan(4, cuts, annotations, 200f, measure)
        assertEquals(1, wide.size)
        assertEquals(170f, wide.single().width, 0f) // max(40,100,100,20) would falsely report100.
    }

    @Test fun shortOrExhaustedNonemptyReadingNeverBecomesAnEmptyContinuation() {
        val cuts = listOf(NativeRubyBaseCut(0, 0, 0f), NativeRubyBaseCut(0, 2, 20f),
            NativeRubyBaseCut(0, 4, 40f), NativeRubyBaseCut(0, 6, 60f), NativeRubyBaseCut(1, 0, 80f))
        val oneWord = reading(7, 0, 1, 0 to 0f, 4 to 20f)
        val unbroken = nativeRubyBreakPlan(1, cuts, listOf(oneWord), 30f, singleBaseWidth(listOf(oneWord)))
        assertEquals(1, unbroken.size)
        assertEquals(NativeRubySourceSlice(0, 4), unbroken.single().readings[7])
        assertEquals(80f, unbroken.single().width, 0f)
        val twoWords = reading(7, 0, 1, 0 to 0f, 3 to 10f, 5 to 20f)
        val split = nativeRubyBreakPlan(1, cuts, listOf(twoWords), 30f, singleBaseWidth(listOf(twoWords)))
        assertEquals(2, split.size)
        assertEquals(NativeRubySourceSlice(0, 3), split[0].readings[7])
        assertEquals(NativeRubySourceSlice(3, 5), split[1].readings[7])
        assertEquals(60f, split[1].width, 0f)
        assertTrue(split.all { it.readings.getValue(7).from < it.readings.getValue(7).to })
        assertEquals(cuts.last(), split.last().baseTo)
        val parallel = listOf(twoWords, oneWord.copy(id = 8))
        val blocked = nativeRubyBreakPlan(1, cuts, parallel, 30f, singleBaseWidth(parallel))
        assertEquals(1, blocked.size)
        assertEquals(mapOf(7 to NativeRubySourceSlice(0, 5), 8 to NativeRubySourceSlice(0, 4)),
            blocked.single().readings) // Every parallel visible reading must admit the split.
    }

    @Test fun visibleEmptyBlocksOnlyItsCoveredAssociationAndHiddenAddsNoTrack() {
        val cuts = (0..3).map { NativeRubyBaseCut(it, 0, it * 10f) }
        val measure = { from: NativeRubyBaseCut, to: NativeRubyBaseCut, _: Map<Int, NativeRubySourceSlice> ->
            to.advance - from.advance }
        val empty = reading(44, 0, 2, 0 to 0f)
        val visible = nativeRubyBreakPlan(3, cuts, listOf(empty), 10f, measure)
        assertEquals(listOf(2, 3), visible.map { it.baseTo.baseIndex })
        assertEquals(mapOf(44 to NativeRubySourceSlice(0, 0)), visible[0].readings)
        assertTrue(visible[1].readings.isEmpty())
        assertEquals(20f, visible[0].width, 0f)
        val hidden = nativeRubyBreakPlan(3, cuts, emptyList(), 10f, measure)
        assertEquals(listOf(1, 2, 3), hidden.map { it.baseTo.baseIndex })
        assertTrue(hidden.all { it.readings.isEmpty() })
        val local = nativeRubyBreakPlan(3, cuts, listOf(empty.copy(baseStart = 1, baseCount = 1)), 10f, measure)
        assertEquals(listOf(1, 2, 3), local.map { it.baseTo.baseIndex })
        assertEquals(listOf(emptyMap(), mapOf(44 to NativeRubySourceSlice(0, 0)), emptyMap()), local.map { it.readings })
    }

    @Test fun actualSpanningAllocationCanBackOffProportionalReadingCuts() {
        val cuts = listOf(NativeRubyBaseCut(0, 0, 0f), NativeRubyBaseCut(1, 2, 60f), NativeRubyBaseCut(3, 0, 120f))
        val annotations = listOf(reading(5, 0, 2, 0 to 0f, 2 to 10f, 6 to 50f, 10 to 80f),
            reading(9, 1, 2, 0 to 0f, 3 to 10f, 8 to 50f, 12 to 80f))
        val observed = mutableListOf<Map<Int, NativeRubySourceSlice>>()
        val measure = { from: NativeRubyBaseCut, to: NativeRubyBaseCut, slices: Map<Int, NativeRubySourceSlice> ->
            val first = from.baseIndex
            val end = to.baseIndex + if (to.offset > 0) 1 else 0
            val columns = (first until end).map { index ->
                (if (to.baseIndex == index) 20f else 40f) - (if (from.baseIndex == index && from.offset > 0) 20f else 0f)
            }
            if (from.baseIndex == 0 && to.offset == 2) observed += slices.toMap()
            val constraints = slices.map { (id, slice) ->
                val reading = annotations.single { it.id == id }
                val coveredFirst = maxOf(first, reading.baseStart)
                val coveredEnd = minOf(end, reading.baseStart + reading.baseCount)
                NativeRubyWidthConstraint(coveredFirst - first, coveredEnd - coveredFirst, width(reading, slice))
            }
            nativeRubyColumnWidths(columns, List(columns.size) { 0f }, constraints).sum()
        }
        val plan = nativeRubyBreakPlan(3, cuts, annotations, 70f, measure)
        assertEquals(2, plan.size)
        assertTrue(observed.contains(mapOf(5 to NativeRubySourceSlice(0, 6), 9 to NativeRubySourceSlice(0, 8))))
        assertEquals(mapOf(5 to NativeRubySourceSlice(0, 2), 9 to NativeRubySourceSlice(0, 3)), plan.first().readings)
        assertEquals(60f, plan.first().width, 0f)
        assertEquals(mapOf(5 to NativeRubySourceSlice(2, 10), 9 to NativeRubySourceSlice(3, 12)), plan.last().readings)
        assertEquals(110f, plan.last().width, 0f)
    }

    @Test fun malformedEndpointsAndInvalidMeasurementsFailWithoutMutatingValidInputs() {
        val cuts = listOf(NativeRubyBaseCut(0, 0, 0f), NativeRubyBaseCut(1, 0, 10f))
        val annotation = reading(2, 0, 1, 0 to 0f, 2 to 10f)
        fun bad(body: () -> Unit) {
            try { body(); fail("Expected invalid native planning input") } catch (_: IllegalArgumentException) { }
        }
        bad { nativeRubyBreakPlan(1, cuts, listOf(annotation, annotation), 10f, singleBaseWidth(listOf(annotation))) }
        bad { nativeRubyBreakPlan(1, cuts, listOf(annotation.copy(opportunities = annotation.opportunities.reversed())),
            10f, singleBaseWidth(listOf(annotation))) }
        bad { nativeRubyBreakPlan(1, cuts, listOf(annotation.copy(baseCount = 2)), 10f, singleBaseWidth(listOf(annotation))) }
        bad { nativeRubyBreakPlan(1, cuts, listOf(annotation), 10f) { _, _, _ -> Float.NaN } }
        val recovered = nativeRubyBreakPlan(1, cuts, listOf(annotation), 10f, singleBaseWidth(listOf(annotation)))
        assertEquals(1, recovered.size)
        assertSame(cuts.first(), recovered.single().baseFrom)
        assertSame(cuts.last(), recovered.single().baseTo)
        assertEquals(listOf(NativeRubyReadingCut(0, 0f), NativeRubyReadingCut(2, 10f)), annotation.opportunities)
        assertEquals(10f, nativeRubyBreakPlan(1, cuts, listOf(annotation), 0f,
            singleBaseWidth(listOf(annotation))).single().width, 0f)
    }

    @Test fun successiveFragmentsUseTheirActualSourceBandAndPreserveConstantWidthCalls() {
        val cuts = (0..4).map { NativeRubyBaseCut(it, 0, it * 10f) }
        val annotation = reading(81, 0, 4, 0 to 0f, 2 to 10f, 4 to 20f, 6 to 30f, 8 to 40f)
        // One reading covers the complete fragment; there are no partial spanning constraints.
        val measure = { from: NativeRubyBaseCut, to: NativeRubyBaseCut, slices: Map<Int, NativeRubySourceSlice> ->
            maxOf(to.advance - from.advance, width(annotation, slices.getValue(81))) }
        val constant = nativeRubyBreakPlan(4, cuts, listOf(annotation), 15f, measure)
        assertEquals(listOf(1, 2, 3, 4), constant.map { it.baseTo.baseIndex })
        val observed = mutableListOf<NativeRubyBaseCut>()
        val varied = nativeRubyBreakPlan(4, cuts, listOf(annotation), 99f, measuredWidth = measure,
            availableWidthAt = { from ->
                observed += from
                when (from.baseIndex) { 0 -> 15f; 1 -> 25f; 3 -> 10f; else -> error("Unexpected fragment start") }
            })
        assertEquals(listOf(1, 3, 4), varied.map { it.baseTo.baseIndex })
        assertEquals(listOf(10f, 20f, 10f), varied.map { it.width })
        assertEquals(listOf(cuts[0], cuts[1], cuts[3]), observed)
        assertEquals(listOf(NativeRubySourceSlice(0, 2), NativeRubySourceSlice(2, 6), NativeRubySourceSlice(6, 8)),
            varied.map { it.readings.getValue(81) })
        try {
            nativeRubyBreakPlan(4, cuts, listOf(annotation), 15f, measuredWidth = measure,
                availableWidthAt = { Float.NaN })
            fail("Invalid actual band must be rejected")
        } catch (_: IllegalArgumentException) { }
        assertEquals(constant, nativeRubyBreakPlan(4, cuts, listOf(annotation), 15f, measure))
    }

    @Test fun oneStepRetriesInadmissibleReadingTuplesAndKeepsDistinctContinuationCertificates() {
        val cuts = listOf(NativeRubyBaseCut(0, 0, 0f), NativeRubyBaseCut(0, 3, 20f), NativeRubyBaseCut(1, 0, 40f))
        val annotation = reading(71, 0, 1, 0 to 0f, 2 to 10f, 4 to 20f, 6 to 30f, 8 to 40f)
        val initial = NativeRubyBreakCursor(cuts.first(), mapOf(71 to 0))
        val sourceIdentity = Any()
        data class Certificate(val source: Any, val path: String, val slice: NativeRubySourceSlice)
        fun first(allowMiddle: Boolean): Pair<NativeRubyBreakStep<Certificate>, List<Int>> {
            val trials = mutableListOf<Int>()
            val result = nativeRubyNextBreak(1, cuts, listOf(annotation), initial, 20f) { from, to, slices ->
                val slice = slices.getValue(71)
                trials += slice.to
                if (to == cuts[1] && slice.to == 4 && !allowMiddle) null
                else NativeRubyBreakCandidate(maxOf(to.advance - from.advance, width(annotation, slice)),
                    Certificate(sourceIdentity, "owner/base0/nested/reading71", slice))
            }
            return checkNotNull(result) to trials
        }
        val (earlier, trials) = first(false)
        val (middle, alternatives) = first(true)
        assertEquals(listOf(8, 4, 2), trials)
        assertEquals(listOf(8, 4), alternatives)
        assertSame(cuts[1], earlier.fragment.baseTo)
        assertSame(cuts[1], middle.fragment.baseTo)
        assertEquals(NativeRubySourceSlice(0, 2), earlier.fragment.readings[71])
        assertEquals(NativeRubySourceSlice(0, 4), middle.fragment.readings[71])
        assertEquals(mapOf(71 to 2), earlier.nextCursor.readingOffsets)
        assertEquals(mapOf(71 to 4), middle.nextCursor.readingOffsets)
        assertSame(sourceIdentity, earlier.certificate.source)
        assertEquals(earlier.fragment.readings.getValue(71), earlier.certificate.slice)
        assertEquals(middle.fragment.readings.getValue(71), middle.certificate.slice)
        val sourceText = "abcdefgh"
        for (selected in listOf(earlier, middle)) {
            val tail = checkNotNull(nativeRubyNextBreak(1, cuts, listOf(annotation), selected.nextCursor, 40f) {
                    from, to, slices ->
                val slice = slices.getValue(71)
                NativeRubyBreakCandidate(maxOf(to.advance - from.advance, width(annotation, slice)),
                    Certificate(sourceIdentity, selected.certificate.path, slice))
            })
            assertEquals(NativeRubySourceSlice(selected.certificate.slice.to, 8), tail.certificate.slice)
            assertEquals(sourceText, listOf(selected, tail).joinToString("") {
                sourceText.substring(it.certificate.slice.from, it.certificate.slice.to)
            })
            assertSame(sourceIdentity, tail.certificate.source)
            assertEquals(cuts.last(), tail.nextCursor.baseFrom)
            assertEquals(mapOf(71 to 8), tail.nextCursor.readingOffsets)
            assertNull(nativeRubyNextBreak<Certificate>(1, cuts, listOf(annotation), tail.nextCursor, 40f) { _, _, _ ->
                fail("A complete cursor must not request a new candidate")
                null
            })
        }
        assertEquals(mapOf(71 to 0), initial.readingOffsets)
        val legacy = nativeRubyBreakPlan(1, cuts, listOf(annotation), 20f, singleBaseWidth(listOf(annotation)))
        assertEquals(legacy.first(), middle.fragment)
    }

    @Test fun nullableAdmissionPreservesRealOverflowAndNullableCertificatesWithoutAdvancingRefusals() {
        val cuts = listOf(NativeRubyBaseCut(0, 0, 0f), NativeRubyBaseCut(0, 3, 20f), NativeRubyBaseCut(1, 0, 40f))
        val annotation = reading(8, 0, 1, 0 to 0f, 2 to 10f, 4 to 20f, 6 to 30f, 8 to 40f)
        val initial = NativeRubyBreakCursor(cuts.first(), mapOf(8 to 0))
        val admitted = Any()
        val trials = mutableListOf<Int>()
        val overflow = checkNotNull(nativeRubyNextBreak(1, cuts, listOf(annotation), initial, 10f) { _, to, slices ->
            trials += slices.getValue(8).to
            when {
                to == cuts.last() -> NativeRubyBreakCandidate(60f, Any())
                slices.getValue(8).to == 4 -> NativeRubyBreakCandidate(31f, admitted)
                else -> null
            }
        })
        assertEquals(listOf(8, 4, 2), trials)
        assertEquals(cuts[1], overflow.fragment.baseTo)
        assertEquals(31f, overflow.fragment.width, 0f)
        assertEquals(NativeRubySourceSlice(0, 4), overflow.fragment.readings[8])
        assertEquals(mapOf(8 to 4), overflow.nextCursor.readingOffsets)
        assertSame(admitted, overflow.certificate) // The last attempted tuple was refused.
        assertNull(nativeRubyNextBreak<Any>(1, cuts, listOf(annotation), initial, 10f) { _, _, _ -> null })
        assertEquals(mapOf(8 to 0), initial.readingOffsets)
        val zero = checkNotNull(nativeRubyNextBreak<String?>(1, cuts, listOf(annotation), initial, 0f) { _, _, _ ->
            NativeRubyBreakCandidate(0f, null)
        })
        assertEquals(0f, zero.fragment.width, 0f)
        assertEquals(cuts.last(), zero.nextCursor.baseFrom)
        assertEquals(mapOf(8 to 8), zero.nextCursor.readingOffsets)
        assertNull(zero.certificate) // A nullable certificate is not nullable admission.
        try {
            nativeRubyNextBreak(1, cuts, listOf(annotation), initial, 10f) { _, _, _ ->
                NativeRubyBreakCandidate(Float.NaN, Unit)
            }
            fail("Invalid admitted width must be rejected")
        } catch (_: IllegalArgumentException) { }
        val recovered = checkNotNull(nativeRubyNextBreak(1, cuts, listOf(annotation), initial, 40f) { from, to, slices ->
            NativeRubyBreakCandidate(singleBaseWidth(listOf(annotation))(from, to, slices), Unit)
        })
        assertEquals(40f, recovered.fragment.width, 0f)
        assertEquals(cuts.last(), recovered.nextCursor.baseFrom)
    }

    @Test fun cursorValidationPreservesAssociationOwnershipAndRejectsInventedContinuation() {
        val cuts = listOf(NativeRubyBaseCut(0, 0, 0f), NativeRubyBaseCut(1, 0, 10f),
            NativeRubyBaseCut(1, 1, 15f), NativeRubyBaseCut(2, 0, 20f), NativeRubyBaseCut(2, 1, 25f),
            NativeRubyBaseCut(3, 0, 30f))
        val readings = listOf(reading(1, 1, 1, 0 to 0f, 2 to 5f, 4 to 10f), reading(2, 2, 1, 0 to 0f))
        fun bad(cursor: NativeRubyBreakCursor) {
            try {
                nativeRubyNextBreak<Unit>(3, cuts, readings, cursor, 10f) { _, _, _ ->
                    fail("Invalid cursor must fail before measurement")
                    null
                }
                fail("Invalid source continuation must be rejected")
            } catch (_: IllegalArgumentException) { }
        }
        bad(NativeRubyBreakCursor(cuts.first().copy(advance = 1f), mapOf(1 to 0, 2 to 0)))
        bad(NativeRubyBreakCursor(cuts.first(), mapOf(1 to 0)))
        bad(NativeRubyBreakCursor(cuts.first(), mapOf(1 to 0, 2 to 0, 3 to 0)))
        bad(NativeRubyBreakCursor(cuts.first(), mapOf(1 to 2, 2 to 0))) // Not reached this association.
        bad(NativeRubyBreakCursor(cuts[2], mapOf(1 to 0, 2 to 0)))
        bad(NativeRubyBreakCursor(cuts[2], mapOf(1 to 4, 2 to 0))) // Nonempty EOF cannot resume inside.
        bad(NativeRubyBreakCursor(cuts[2], mapOf(1 to 1, 2 to 0))) // Not an ordinary reading opportunity.
        bad(NativeRubyBreakCursor(cuts[3], mapOf(1 to 2, 2 to 0))) // Completed association must finish reading.
        bad(NativeRubyBreakCursor(cuts[4], mapOf(1 to 4, 2 to 0))) // Visible-empty cannot split internally.
        val resumed = checkNotNull(nativeRubyNextBreak(3, cuts, readings,
            NativeRubyBreakCursor(cuts[2], mapOf(1 to 2, 2 to 0)), 5f) { from, to, slices ->
            NativeRubyBreakCandidate(to.advance - from.advance, slices.toMap())
        })
        assertEquals(cuts[3], resumed.fragment.baseTo)
        assertEquals(mapOf(1 to NativeRubySourceSlice(2, 4)), resumed.certificate)
        assertEquals(mapOf(1 to 4, 2 to 0), resumed.nextCursor.readingOffsets)
        val empty = checkNotNull(nativeRubyNextBreak(3, cuts, readings, resumed.nextCursor, 5f) { from, to, slices ->
            NativeRubyBreakCandidate(to.advance - from.advance, slices.toMap())
        })
        assertEquals(cuts.last(), empty.fragment.baseTo)
        assertEquals(10f, empty.fragment.width, 0f)
        assertEquals(mapOf(2 to NativeRubySourceSlice(0, 0)), empty.certificate)
        assertEquals(mapOf(1 to 4, 2 to 0), empty.nextCursor.readingOffsets)
    }
}
