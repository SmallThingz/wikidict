package app.smallthingz.dict

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure policy and immutable proof arithmetic. The native API31 shaping/paint path
 * also requires its own device qualification. */
class NativeRubySpacingTest {
    private fun candidates(text: String, language: String = "en", boundaries: List<Int> =
        (0..text.length).toList()): List<Int> = nativeRubySpacingCandidates(text, boundaries) { language }

    @Test fun cjkPunctuationUsesActualDominantScriptAndLanguageWithoutInventingLatinOrBopomofoGaps() {
        assertEquals(listOf(1, 2), candidates("\u6f22,\u5b57"))
        assertEquals(listOf(1), candidates("\u3042\u3044"))
        assertEquals(listOf(1), candidates("\u30a2\u30a4"))
        assertEquals(listOf(1), candidates("\ud55c\uae00"))
        assertEquals(emptyList<Int>(), candidates("Latin"))
        assertEquals(emptyList<Int>(), candidates("\u3105\u3106", "zh"))
        assertEquals(emptyList<Int>(), candidates("\u0628\u0628", "ar"))
        assertEquals(emptyList<Int>(), candidates("\u6f22 \u5b57"))
        assertEquals(emptyList<Int>(), candidates("\u6f22\u00a0\u5b57"))
        assertEquals(emptyList<Int>(), candidates("\u6f22\ufffc\u5b57", "ja"))

        // The exact same Common comma is not promoted by an ambient UI language.
        assertEquals(emptyList<Int>(), candidates("\u6f22, A", "en"))
        assertEquals(listOf(1), candidates("\u6f22, A", "ja"))
        assertEquals(listOf(1), candidates("\u6f22, A", "zh"))
        assertEquals(emptyList<Int>(), candidates("\u6f22, AA", "ja"))
        assertEquals(emptyList<Int>(), candidates("\ud55c, A", "ja"))
        assertEquals(listOf(1), candidates("\ud55c, A", "ko"))
        assertEquals(emptyList<Int>(), candidates(",.", "en"))
        assertEquals(listOf(1), candidates(",.", "ja"))
    }

    @Test fun graphemeCandidatesKeepSurrogatesMarksTokensAndPairedPunctuationIntact() {
        val markedSupplementaryHan = "\ud840\udc00\u0301\u5b57"
        assertEquals(listOf(3), candidates(markedSupplementaryHan, boundaries = listOf(0, 3, 4)))
        assertEquals(listOf(1, 3), candidates("\u6f22\u2014\u2014\u5b57"))
        assertEquals(listOf(1, 3), candidates("\u6f22\u2026\u22ef\u5b57"))
        assertEquals(emptyList<Int>(), candidates("\u6f22\u200d\u5b57", boundaries = listOf(0, 2, 3)))
        assertEquals(emptyList<Int>(), candidates("\u2066\u6f22\u2069", boundaries = listOf(0, 1, 2, 3)))
        assertEquals(emptyList<Int>(), candidates("", boundaries = listOf(0)))
        val actualLanguages = mapOf(0 to "en", 1 to "ja", 2 to "en", 3 to "en")
        assertEquals(listOf(1), nativeRubySpacingCandidates("\u6f22, A", listOf(0, 1, 2, 3, 4)) {
            actualLanguages.getValue(it)
        })
    }

    private fun glyph(id: Int, x: Float, font: String = "source-font", y: Float = 0f) =
        NativeRubyGlyph(id, font, x, y)

    @Test fun glyphProofRetainsFullNativeFontPositionsAndBothPhysicalRunDirections() {
        val first = NativeRubyGlyphRun(10f, listOf(glyph(11, 0f)))
        val second = NativeRubyGlyphRun(12f, listOf(glyph(12, 0f)))
        val ltr = NativeRubyGlyphRun(22f, listOf(glyph(11, 0f), glyph(12, 10f)))
        val rtl = NativeRubyGlyphRun(22f, listOf(glyph(12, 0f), glyph(11, 12f)))
        assertTrue(nativeRubyEquivalentSplit(ltr, first, second, false))
        assertTrue(nativeRubyEquivalentSplit(rtl, first, second, true))
        assertFalse(nativeRubyEquivalentSplit(ltr, first, second, true))
        assertFalse(nativeRubyEquivalentSplit(rtl, first, second, false))
        assertFalse(nativeRubyEquivalentSplit(ltr, first, second.copy(glyphs = listOf(glyph(12, 0f, "fallback-font"))), false))
        assertFalse(nativeRubyEquivalentSplit(ltr, first, second.copy(glyphs = listOf(glyph(12, 0.25f))), false))
        assertFalse(nativeRubyEquivalentSplit(ltr, first, second.copy(glyphs = listOf(glyph(12, 0f, y = 1f))), false))
    }

    @Test fun ligatureSharedClusterAndChangedAdvanceNeverBecomeSpacingOpportunities() {
        val first = NativeRubyGlyphRun(10f, listOf(glyph(1, 0f)))
        val second = NativeRubyGlyphRun(10f, listOf(glyph(2, 0f)))
        val ligature = NativeRubyGlyphRun(20f, listOf(glyph(99, 0f)))
        assertFalse(nativeRubyEquivalentSplit(ligature, first, second, false))
        val ordinary = NativeRubyGlyphRun(20f, listOf(glyph(1, 0f), glyph(2, 10f)))
        assertFalse(nativeRubyEquivalentSplit(ordinary, first.copy(advance = 9.75f), second, false))
        assertFalse(nativeRubyEquivalentSplit(ordinary, first.copy(advance = 0f), second.copy(advance = 20f), false))
        assertFalse(nativeRubyEquivalentSplit(ordinary, first, second.copy(advance = Float.NaN), false))
        assertFalse(nativeRubyEquivalentSplit(ordinary.copy(glyphs = ordinary.glyphs + glyph(2, 10f)), first, second, false))
        val tiny = NativeRubyGlyphRun(0.0002f, listOf(glyph(1, 0f), glyph(2, 0.0001f)))
        val tinyFirst = NativeRubyGlyphRun(0.0001f, listOf(glyph(1, 0f)))
        val tinySecond = NativeRubyGlyphRun(0.0001f, listOf(glyph(2, 0f)))
        assertTrue(nativeRubyEquivalentSplit(tiny, tinyFirst, tinySecond, false))
        assertFalse(nativeRubyEquivalentSplit(tiny, tinyFirst,
            tinySecond.copy(glyphs = listOf(glyph(2, 0.00001f))), false))
    }

    @Test fun physicalDistributionNormalizesFractionalRtlOriginAndDoesNotTurnInsertedGapsIntoSource() {
        val map = NativeRubySpacingMap(0.25f, 30f, 42f,
            listOf(NativeRubyPhysicalCut(1, 20.25f), NativeRubyPhysicalCut(2, 10.25f)))
        assertEquals(listOf(2, 1), map.cuts.map { it.sourceOffset })
        assertEquals(2f, map.physical(0.25f), 0f)
        assertEquals(12f, map.physical(10.25f, after = false), 0f)
        assertEquals(16f, map.physical(10.25f), 0f)
        assertEquals(26f, map.physical(20.25f, after = false), 0f)
        assertEquals(30f, map.physical(20.25f), 0f)
        assertEquals(40f, map.physical(30.25f), 0f)
        assertEquals(1.75f, map.shiftAt(5.25f), 0f)
        assertEquals(5.75f, map.shiftAt(15.25f), 0f)
        assertEquals(9.75f, map.shiftAt(25.25f), 0f)
        assertEquals(10.25f, map.original(14f), 0f)
        assertEquals(20.25f, map.original(28f), 0f)
        assertEquals(0.25f, map.original(2f), 0f)
        assertEquals(30.25f, map.original(40f), 0f)
        val tiny = NativeRubySpacingMap(0f, 0.0003f, 3.0003f,
            listOf(NativeRubyPhysicalCut(1, 0.0001f), NativeRubyPhysicalCut(2, 0.0002f)))
        assertEquals(2, tiny.cuts.size)
        assertTrue(tiny.physical(0.0002f) > tiny.physical(0.0001f))
    }

    @Test fun noOpportunityCentersTheIntactAdvanceAndInvalidPhysicalProofIsRejected() {
        val center = NativeRubySpacingMap(0.5f, 12.5f, 22.5f, emptyList())
        assertEquals(5f, center.physical(0.5f), 0f)
        assertEquals(17.5f, center.physical(13f), 0f)
        assertEquals(4.5f, center.minimumShift, 0f)
        assertEquals(center.minimumShift, center.maximumShift, 0f)
        fun refused(cuts: List<NativeRubyPhysicalCut>) {
            var failure: IllegalArgumentException? = null
            try { NativeRubySpacingMap(0f, 20f, 24f, cuts) }
            catch (caught: IllegalArgumentException) { failure = caught }
            assertTrue(failure != null)
        }
        refused(listOf(NativeRubyPhysicalCut(1, 0f)))
        refused(listOf(NativeRubyPhysicalCut(1, 20f)))
        refused(listOf(NativeRubyPhysicalCut(1, Float.NaN)))
        refused(listOf(NativeRubyPhysicalCut(1, 10f), NativeRubyPhysicalCut(2, 10f)))
        refused(listOf(NativeRubyPhysicalCut(1, 5f), NativeRubyPhysicalCut(1, 15f)))
    }

    private fun complete(text: String, boundaries: List<Int> = (0..text.length).toList(),
        proof: List<Int> = boundaries.drop(1).dropLast(1)): NativeRubySpacingProfile =
        NativeRubySpacingProfile.source(text, boundaries, { "ja" }, proof, complete = true)
    // Pure fixtures state their physical LTR edges explicitly; production obtains
    // these edges from retained native run geometry before composing a profile.
    private fun compose(profiles: List<NativeRubySpacingProfile>, complete: Boolean = true,
        order: List<Int> = profiles.indices.toList()) = NativeRubySpacingProfile.compose(
        profiles.map { it.withPhysicalEdges(it.firstEdge, it.lastEdge) }, order, complete)
    private fun item(profile: NativeRubySpacingProfile, width: Float, nested: Boolean,
        reversed: Boolean = false) = NativeRubyHierarchyItem(Any(), profile, width, nested, reversed)
    private fun unavailable(block: () -> Unit) {
        var caught: UnsupportedFloatLayout? = null
        try { block() } catch (failure: UnsupportedFloatLayout) { caught = failure }
        assertTrue(caught != null)
    }
    private fun totalIncrement(plan: NativeRubyHierarchyPlan): Float = plan.leadingIncrement +
        plan.trailingIncrement + plan.gaps.sum() + plan.placements.sumOf { it.widthIncrement.toDouble() }.toFloat()

    @Test fun completeHierarchyProfilesRetainSourceUnitsAndRequireEveryNativeInteriorProof() {
        val single = complete("\u6f22")
        assertEquals(1, single.units); assertEquals(0, single.interiorOpportunities)
        val marked = complete("\ud840\udc00\u0301\u5b57", listOf(0, 3, 4), listOf(3))
        assertEquals(2, marked.units)
        assertEquals("\ud840\udc00\u0301", marked.firstUnit)
        assertEquals("\u5b57", marked.lastUnit)
        // Native proof may arrive in physical RTL order; source cuts still match exactly.
        assertEquals(3, complete("\u6f22,\u5b57", proof = listOf(2, 1)).units)
        unavailable { complete("\u6f22\u5b57", proof = emptyList()) }
        unavailable { complete("\u6f22,\u5b57", proof = listOf(1, 1)) }
        unavailable { complete("\u6f22,\u5b57", proof = listOf(1, 3)) }
        unavailable { NativeRubySpacingProfile.source("\u6f22", listOf(0, 1), { "ja" }, emptyList(), complete = false) }
        for (value in listOf("", "\ufffc", "\u6f22 \u5b57", "\u6f22\u2014\u2014\u5b57"))
            unavailable { complete(value) }
        for (value in listOf("Latin", "\u3105\u3106", "\u0628\u0628")) {
            val intact = complete(value, proof = emptyList())
            assertTrue(intact.zeroOpportunities)
            assertEquals(0, intact.interiorOpportunities)
        }
        val zeros = compose(listOf(complete("A"), complete("B")), complete = true)
        assertTrue(zeros.zeroOpportunities)
        assertEquals(0, compose(listOf(complete("A"), single), complete = true).interiorOpportunities)
        val centered = nativeRubyHierarchyPlan(listOf(item(zeros, 50f, nested = true)), 4f)
        assertEquals(NativeRubySpacingIncrement(2f, 2f, 4f), centered.placements.single().increment)
        assertEquals(54f, centered.placements.single().newWidth, 0f)
        // Source-region context proves the Common comma; it is not reclassified as
        // an isolated English punctuation run when the verified row is partitioned.
        val units = NativeRubySpacingProfile.sourceUnits("\u6f22,\u5b57", listOf(0, 1, 2, 3),
            { "en" }, listOf(1, 2), complete = true)
        assertEquals(3, units.size)
        assertEquals(NativeRubySpacingEdge(",", true), units[1].firstEdge)
        assertEquals(units[1].firstEdge, units[1].lastEdge)
        val nested = compose(listOf(single, marked), complete = true)
        assertEquals(3, nested.units); assertEquals(2, nested.interiorOpportunities)
        assertEquals(single.firstUnit, nested.firstUnit); assertEquals(marked.lastUnit, nested.lastUnit)
        unavailable { compose(listOf(single), complete = false) }
        unavailable { compose(emptyList(), complete = true) }
        assertEquals(0, compose(listOf(complete("\u2014"), complete("\u2014")), complete = true).interiorOpportunities)
    }

    @Test fun hierarchyUsesHalfExternalEdgesAndOnlyTheNewNestedWidthIncrement() {
        val ordinaryLeft = item(complete("\u6f22\u5b57"), 20f, nested = false)
        // 100 already includes this nested owner's annotation-induced slack.
        val nested = item(complete("\u3042\u3044\u3046"), 100f, nested = true)
        val ordinaryRight = item(complete("\u540d"), 10f, nested = false)
        val input = listOf(ordinaryLeft, nested, ordinaryRight)
        val plan = nativeRubyHierarchyPlan(input, 12f)
        assertEquals(2f, plan.unit, 0f)
        assertEquals(1f, plan.leadingIncrement, 0f); assertEquals(1f, plan.trailingIncrement, 0f)
        assertEquals(listOf(1f, 1f), plan.gaps)
        assertEquals(listOf(1f, 4f, 11f), plan.placements.map { it.prefixIncrement })
        assertEquals(listOf(2f, 6f, 0f), plan.placements.map { it.widthIncrement })
        assertEquals(listOf(22f, 106f, 10f), plan.placements.map { it.newWidth })
        assertEquals(listOf(2f, 0f, 2f), plan.placements.map { it.ordinaryInteriorIncrement })
        assertTrue(input.zip(plan.placements).all { (source, placed) -> source.occurrence === placed.occurrence })
        assertEquals(12f, totalIncrement(plan), 0f)
        assertEquals(100f, nested.currentWidth, 0f)
        // Replanning from the immutable original is deterministic; no growth is accumulated.
        assertEquals(plan.placements, nativeRubyHierarchyPlan(input, 12f).placements)
        val unchanged = nativeRubyHierarchyPlan(input, 0f)
        assertEquals(input.map { it.currentWidth }, unchanged.placements.map { it.newWidth })
        assertEquals(0f, totalIncrement(unchanged), 0f)
    }

    @Test fun adjacentAndRecursiveNestedProfilesSupplyTheirOwnHalfEdgesExactlyOnce() {
        val first = item(complete("\u6f22\u5b57"), 80f, nested = true)
        val second = item(complete("\u3042\u3044\u3046"), 90f, nested = true)
        val plan = nativeRubyHierarchyPlan(listOf(first, second), 10f)
        assertEquals(2f, plan.unit, 0f)
        assertEquals(0f, plan.leadingIncrement, 0f); assertEquals(0f, plan.trailingIncrement, 0f)
        assertEquals(listOf(0f), plan.gaps)
        assertEquals(listOf(0f, 4f), plan.placements.map { it.prefixIncrement })
        assertEquals(listOf(4f, 6f), plan.placements.map { it.widthIncrement })
        assertEquals(listOf(84f, 96f), plan.placements.map { it.newWidth })
        val parentProfile = compose(listOf(first.profile, second.profile), complete = true)
        val outer = nativeRubyHierarchyPlan(listOf(item(parentProfile, 200f, nested = true)), 10f)
        assertEquals(10f, outer.placements.single().widthIncrement, 0f)
        assertEquals(210f, outer.placements.single().newWidth, 0f)
        assertEquals(plan.unit, outer.unit, 0f)
        assertEquals(10f, totalIncrement(plan), 0f); assertEquals(10f, totalIncrement(outer), 0f)
        // Current nested slots sum to 170: the independent 30px original owner slack
        // remains 30 after both levels receive their once-only incremental plan.
        assertEquals(30f, outer.placements.single().newWidth - plan.placements.sumOf { it.newWidth.toDouble() }.toFloat(), 0f)
        val reverse = nativeRubyHierarchyPlan(listOf(second.copy(reversedEdges = true), first.copy(reversedEdges = true)), 10f)
        assertEquals(listOf(6f, 4f), reverse.placements.map { it.widthIncrement })
        assertEquals(listOf(0f, 6f), reverse.placements.map { it.prefixIncrement })
        val singleNested = nativeRubyHierarchyPlan(listOf(item(complete("\u6f22"), 50f, nested = true)), 4f)
        assertEquals(4f, singleNested.placements.single().widthIncrement, 0f)
        assertEquals(0f, singleNested.leadingIncrement + singleNested.trailingIncrement, 0f)
    }

    @Test fun hierarchyChecksPhysicalSourceEdgesAndBoundsWithoutInventingSpacing() {
        val left = item(complete("\u6f22\u2014"), 20f, nested = true)
        val right = item(complete("\u2014\u5b57"), 20f, nested = true)
        val pairedDashes = nativeRubyHierarchyPlan(listOf(left, right), 8f)
        assertEquals(listOf(0f), pairedDashes.gaps)
        assertEquals(0f, pairedDashes.placements[0].increment.right, 0f)
        assertEquals(0f, pairedDashes.placements[1].increment.left, 0f)
        // The same source profiles have different actual native-facing edge units.
        val reversed = nativeRubyHierarchyPlan(listOf(left.copy(reversedEdges = true), right), 8f)
        assertEquals(8f, totalIncrement(reversed), 0f)
        val nativeEdges = nativeRubyHierarchyPlan(listOf(left.copy(profile =
            left.profile.withPhysicalEdges(left.profile.lastEdge, left.profile.firstEdge)), right.copy(profile =
            right.profile.withPhysicalEdges(right.profile.firstEdge, right.profile.lastEdge))), 8f)
        assertEquals(8f, totalIncrement(nativeEdges), 0f)
        val ellipsis = item(complete("\u2026"), 10f, nested = true)
        val pairedEllipses = nativeRubyHierarchyPlan(listOf(ellipsis, item(complete("\u22ef"), 10f, nested = true)), 2f)
        assertEquals(listOf(0f), pairedEllipses.gaps)
        assertEquals(listOf(1f, 1f), pairedEllipses.placements.map { it.widthIncrement })
        fun invalid(block: () -> Unit) {
            var caught: IllegalArgumentException? = null
            try { block() } catch (failure: IllegalArgumentException) { caught = failure }
            assertTrue(caught != null)
        }
        invalid { nativeRubyHierarchyPlan(emptyList(), 1f) }
        invalid { nativeRubyHierarchyPlan(listOf(left), Float.NaN) }
        invalid { nativeRubyHierarchyPlan(listOf(left), -1f) }
        invalid { nativeRubyHierarchyPlan(listOf(left.copy(currentWidth = Float.POSITIVE_INFINITY)), 1f) }
        invalid { nativeRubyHierarchyPlan(listOf(left, left), 1f) }
        unavailable { nativeRubyHierarchyPlan(listOf(left.copy(currentWidth = TablePixelLimit.toFloat())), 1024f) }
    }

    @Test fun mixedSourcePiecesKeepUnprovedRunsAndActualPhysicalJoinCounts() {
        val text = "A\u6f22\u5b57B"
        val pieces = NativeRubySpacingProfile.sourcePieces(text, listOf(0, 1, 2, 3, 4),
            { "ja" }, listOf(2), complete = true)
        assertEquals(listOf(0 to 2, 2 to 4), pieces.map { it.start to it.end })
        assertEquals(listOf("A\u6f22", "\u5b57B"), pieces.map { text.substring(it.start, it.end) })
        assertFalse(checkNotNull(pieces.first().profile.firstEdge).eligible)
        assertTrue(checkNotNull(pieces.first().profile.lastEdge).eligible)
        assertTrue(checkNotNull(pieces.last().profile.firstEdge).eligible)
        assertFalse(checkNotNull(pieces.last().profile.lastEdge).eligible)
        assertEquals(1, compose(pieces.map { it.profile }).interiorOpportunities)
        unavailable { NativeRubySpacingProfile.sourcePieces(text, listOf(0, 1, 2, 3, 4),
            { "ja" }, listOf(1, 2, 3), complete = true) }
        unavailable { NativeRubySpacingProfile.sourcePieces(text, listOf(0, 1, 2, 3, 4),
            { "ja" }, emptyList(), complete = true) }
        val a = complete("\u6f22A", proof = emptyList())
        val b = complete("\u5b57B", proof = emptyList())
        val c = complete("\u540d")
        assertEquals(0, compose(listOf(a, b, c)).interiorOpportunities)
        assertEquals(1, compose(listOf(a, b, c), order = listOf(1, 2, 0)).interiorOpportunities)
        unavailable { NativeRubySpacingProfile.compose(listOf(c), listOf(0), complete = true) }
        val comma = NativeRubySpacingProfile.sourcePieces("\u6f22,\u5b57A", listOf(0, 1, 2, 3, 4),
            { "en" }, listOf(1, 2), complete = true)
        assertEquals(NativeRubySpacingEdge(",", true), comma[1].profile.firstEdge)
    }

    @Test fun mixedAndRetainedGapBudgetsNeverSpendAnIneligibleJoinOrRedistributeOldSlack() {
        val gap = NativeRubySpacingProfile.retainedGap()
        assertTrue(gap.retainedGap)
        assertEquals(0, gap.interiorOpportunities)
        assertFalse(checkNotNull(gap.firstEdge).eligible); assertFalse(checkNotNull(gap.lastEdge).eligible)
        val input = listOf(item(complete("A"), 10f, false), item(complete("\u6f22\u5b57"), 60f, true),
            item(complete("\u540d"), 20f, false), item(gap, 7f, false), item(complete("\u304b\u306a"), 30f, true))
        val plan = nativeRubyHierarchyPlan(input, 16f)
        assertEquals(4f, plan.unit, 0f)
        assertEquals(listOf(0f, 2f, 0f, 0f), plan.gaps)
        assertEquals(listOf(0f, 6f, 0f, 0f, 6f), plan.placements.map { it.widthIncrement })
        assertEquals(7f, plan.placements[3].newWidth, 0f)
        assertEquals(NativeRubySpacingIncrement(0f, 2f, 4f), plan.placements[1].increment)
        assertEquals(16f, totalIncrement(plan), 0f)
        assertEquals(listOf(10f, 60f, 20f, 7f, 30f), input.map { it.currentWidth })
        val left = item(complete("\u6f22\u5b57"), 80f, true)
        val right = item(complete("\u540d"), 10f, false)
        val inherited = NativeRubySpacingIncrement(1f, 3f, 4f)
        val twoBudget = nativeRubyHierarchyPlan(listOf(left, right), 6f, inherited)
        assertEquals(6f, twoBudget.unit, 0f) // Original intrinsic u=2, added parent u=4.
        assertEquals(NativeRubySpacingIncrement(2f, 3f, 6f), twoBudget.placements[0].increment)
        assertEquals(listOf(91f, 10f), twoBudget.placements.map { it.newWidth })
        assertEquals(listOf(3f), twoBudget.gaps)
        assertEquals(18f, totalIncrement(twoBudget), 0f) // 6 intrinsic + 1+3 outer + 2*4 interior.
        assertEquals(80f, left.currentWidth, 0f)
        val fraction = nativeRubyHierarchyPlan(listOf(left, item(complete("\u540d"), 10f, true)), 1f)
        assertEquals(listOf(0f), fraction.gaps) // Rounded halves cannot create a negative zero remainder.
        assertEquals(1f, totalIncrement(fraction), .000001f)
    }

    @Test fun sourceEmptyOwnersKeepAllocationButDoNotInventSourceEdgesOrBlockTheNearestJoin() {
        val empty = NativeRubySpacingProfile.sourceEmpty()
        assertTrue(empty.sourceEmpty)
        assertEquals(0, empty.units); assertEquals(0, empty.interiorOpportunities)
        assertNull(empty.firstEdge); assertNull(empty.lastEdge); assertNull(empty.physicalEdges)
        assertTrue(empty.zeroOpportunities); assertFalse(empty.retainedGap)
        val left = complete("\u6f22"); val right = complete("\u5b57")
        val composed = compose(listOf(left, empty, right))
        assertFalse(composed.sourceEmpty)
        assertEquals(2, composed.units); assertEquals(1, composed.interiorOpportunities)
        assertEquals(left.firstEdge, composed.firstEdge); assertEquals(right.lastEdge, composed.lastEdge)
        assertTrue(compose(listOf(empty, empty)).sourceEmpty)
        val inherited = NativeRubySpacingIncrement(1f, 3f, 4f)
        val physical = listOf(item(left, 20f, false), item(empty, 40f, true), item(right, 20f, false))
        val plan = nativeRubyHierarchyPlan(physical, 0f, inherited)
        assertEquals(listOf(20f, 40f, 20f), plan.placements.map { it.newWidth })
        assertEquals(listOf(1f, 3f, 5f), plan.placements.map { it.prefixIncrement })
        assertEquals(listOf(2f, 2f), plan.gaps)
        assertEquals(NativeRubySpacingIncrement(0f, 0f, 0f), plan.placements[1].increment)
        assertEquals(8f, totalIncrement(plan), 0f)
        assertEquals(88f, physical.sumOf { it.currentWidth.toDouble() }.toFloat() + totalIncrement(plan), 0f)
        assertSame(physical[1].occurrence, plan.placements[1].occurrence)
        val nested = nativeRubyHierarchyPlan(listOf(physical[0].copy(nested = true), physical[1],
            physical[2].copy(nested = true)), 0f, inherited)
        assertEquals(listOf(23f, 40f, 25f), nested.placements.map { it.newWidth })
        assertEquals(listOf(0f, 3f, 3f), nested.placements.map { it.prefixIncrement })
        assertEquals(listOf(0f, 0f), nested.gaps)
        assertEquals(8f, totalIncrement(nested), 0f)
        for (barrier in listOf(NativeRubySpacingProfile.retainedGap(), complete(" "))) {
            assertFalse(barrier.sourceEmpty)
            assertEquals(0, compose(listOf(left, barrier, right)).interiorOpportunities)
            // A retained zero-advance SPACE or a nonempty zero-font source has
            // no empty-source exemption. Width never decides source eligibility.
            val blocked = nativeRubyHierarchyPlan(listOf(physical[0], item(barrier, 0f, false), physical[2]), 0f, inherited)
            assertEquals(listOf(0f, 0f), blocked.gaps)
            assertEquals(4f, totalIncrement(blocked), 0f)
        }
        val onlyEmpty = nativeRubyHierarchyPlan(listOf(item(empty, 40f, true)), 6f, inherited)
        assertEquals(40f, onlyEmpty.placements.single().newWidth, 0f)
        assertEquals(4f, onlyEmpty.leadingIncrement, 0f)
        assertEquals(6f, onlyEmpty.trailingIncrement, 0f)
        assertEquals(10f, totalIncrement(onlyEmpty), 0f)
        unavailable { complete("", listOf(0), emptyList()) }
    }

}
