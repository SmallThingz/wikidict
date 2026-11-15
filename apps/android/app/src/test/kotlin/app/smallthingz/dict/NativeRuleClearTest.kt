package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Pure placement/source controls; actual separator paint and actions use the device control. */
class NativeRuleClearTest {
    private val zero = FloatMargins(0f, 0f, 0f, 0f)
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun rule(clear: FigureClear?, height: Float = 1.25f, top: Float = 3.25f, bottom: Float = 7.5f) =
        NativeFloatContextPart.Rule(4, NativeRuleMetrics(height, 0xff112233.toInt(),
            FloatMargins(top, 30f, bottom, 30f), clear))
    private val exclusions = listOf(
        NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 20f, 40f)),
        NativeFloatExclusion(TableFloatSide.Right, NativeFloatBounds(80f, 0f, 100f, 70f)))
    private fun profile(part: NativeFloatContextPart, preparation: NativeOrdinaryPreparation? = null) =
        checkNotNull(NativeFloatContextGeometry.adjoiningProfile(part, preparation))
    private fun floated(id: Int, side: TableFloatSide, height: Float, measured: MutableList<Int>) =
        NativeFloatContextPart.Child(id, NativeBlockWidth.FixedPx(20f), {
            measured += id
            NativeBlockMeasure(20f, 20f, height)
        }, floatSide = side)
    private fun group(parts: List<NativeFloatContextPart>, isolated: Boolean) = NativeFloatContextPart.Container(
        10, 100, { _, _ -> error("A leading structural query must not build child geometry") },
        margins = zero, padding = zero, isolatesFloats = isolated, preparedParts = parts)

    @Test fun clearTransportLeavesResolvedHeightFillMarginsAndLegacyNoneGeometryExact() {
        val source = RuleStyle(px(1f), ContainerColor.LightDark("#112233", "#abcdef"),
            StyleEdges(StyleLength(StyleLengthUnit.Em, .2f), px(4f), px(2f), px(3f)))
        val old = resolveAuthoredRuleMetrics(source, 1.25f, 17.5f, false)
        assertNull(old.clear)
        assertEquals(1.25f, old.height, 0f)
        assertEquals(FloatMargins(3.5f, 5f, 2.5f, 3.75f), old.margins)
        for (clear in FigureClear.entries) {
            val actual = resolveAuthoredRuleMetrics(source.copy(clear = clear), 1.25f, 17.5f, false)
            assertEquals(old, actual.copy(clear = null))
            assertEquals(clear, nativeClearForPart(NativeFloatContextPart.Rule(4, actual)))
            assertEquals(clear != FigureClear.None, actual.requiresClearanceOwner)
            assertEquals(old.intrinsic(), actual.intrinsic())
            assertEquals(old.contentWidth(100.5f), actual.contentWidth(100.5f), 0f)
            assertEquals(old.allocatedWidth(100.5f), actual.allocatedWidth(100.5f))
        }
        assertFalse(old.requiresClearanceOwner)
        assertEquals(source, source.copy(clear = null))
    }

    @Test fun everyPhysicalClearUsesTheSelectedFloatBottomWithoutAddingTopMarginAgain() {
        val expected = mapOf<FigureClear?, Float>(null to 15f, FigureClear.None to 15f,
            FigureClear.Left to 40f, FigureClear.Right to 70f, FigureClear.Both to 70f)
        for ((clear, top) in expected) {
            val cursor = NativeMarginCursor(NativeMarginCollapse(false, false))
            val previous = NativeAdjoiningMargins(0f, 5f, false)
            cursor.end(cursor.begin(previous), 10f, previous)
            val part = rule(clear)
            val margins = profile(part)
            val placed = cursor.begin(margins, nativeClearBottom(nativeClearForPart(part), exclusions))
            assertEquals(top, placed.borderTop, 0f)
            if (clear == null || clear == FigureClear.None) assertNull(placed.clearance)
            else assertEquals(top - 18.25f, checkNotNull(placed.clearance), 0f)
            cursor.end(placed, part.metrics.height, margins)
            assertEquals(top + 8.75f, cursor.begin(NativeAdjoiningMargins(6.25f, 0f, false)).borderTop, 0f)
            assertEquals(40f, part.metrics.contentWidth(100f), 0f)
        }
        assertEquals(40f, nativeClearBottom(FigureClear.Left, exclusions.reversed())!!, 0f)
        assertEquals(70f, nativeClearBottom(FigureClear.Right, exclusions.reversed())!!, 0f)
    }

    @Test fun zeroHeightClearanceBreaksParentAdjacencyButRetainsItsOwnThroughMarginSet() {
        fun nextTop(clear: FigureClear?, height: Float): Float {
            val cursor = NativeMarginCursor(NativeMarginCollapse(false, false))
            val previous = NativeAdjoiningMargins(0f, 4f, false)
            cursor.end(cursor.begin(previous), 10f, previous)
            val part = rule(clear, height, 7f, 11f)
            val margins = profile(part)
            val placed = cursor.begin(margins, nativeClearBottom(nativeClearForPart(part), exclusions))
            cursor.end(placed, height, margins)
            return cursor.begin(NativeAdjoiningMargins(8f, 0f, false)).borderTop
        }
        assertEquals(21f, nextTop(null, 0f), 0f)
        assertEquals(21f, nextTop(FigureClear.None, 0f), 0f)
        assertEquals(74f, nextTop(FigureClear.Right, 0f), 0f)
        assertEquals(81.25f, nextTop(FigureClear.Right, .25f), 0f)

        val part = rule(FigureClear.Right, 0f, 7f, 11f)
        val preparation = NativeOrdinaryPreparation(listOf(part))
        preparation.markClearance(part)
        val cleared = profile(part, preparation)
        assertTrue(cleared.through)
        assertFalse(cleared.beforeAdjoins)
        assertFalse(cleared.afterAdjoins)
        val root = NativeMarginCursor(NativeMarginCollapse(true, true))
        val placed = root.begin(cleared, 70f, resolvedClearance = true)
        root.end(placed, 0f, cleared)
        assertEquals(70f, placed.borderTop, 0f)
        assertEquals(74f, root.finish(), 0f)
        assertEquals(NativeAdjoiningMargins(0f, 0f, false),
            NativeAdjoiningMargins.sequence(listOf(cleared)))
    }

    @Test fun bodyLeadingClearanceUsesPreparedFloatIdentityAndDoesNotRepeatMeasurement() {
        for (clear in listOf<FigureClear?>(null, FigureClear.None, FigureClear.Left, FigureClear.Right, FigureClear.Both)) {
            val measured = mutableListOf<Int>()
            val left = floated(1, TableFloatSide.Left, 40f, measured)
            val right = floated(2, TableFloatSide.Right, 70f, measured)
            val part = rule(clear)
            val parts = listOf(left, right, part)
            val preparation = NativeOrdinaryPreparation(parts)
            preparation.resolveBodyLeading(parts, 100)
            assertEquals(clear != null && clear != FigureClear.None, preparation.hasClearance(part))
            assertEquals(listOf(1, 2), measured)
            val actual = profile(part, preparation)
            assertEquals(clear == null || clear == FigureClear.None, actual.beforeAdjoins)
            assertTrue(actual.afterAdjoins)
            assertEquals(part.metrics.margins.top, actual.before, 0f)
            assertEquals(part.metrics.margins.bottom, actual.after, 0f)
            preparation.resolveBodyLeading(parts, 100)
            assertEquals(listOf(1, 2), measured)
        }
    }

    @Test fun isolatedFormattingContextDoesNotClearAnEnclosingFloatButUsesItsOwnFloats() {
        val measured = mutableListOf<Int>()
        val outer = floated(1, TableFloatSide.Right, 100f, measured)
        val innerRule = rule(FigureClear.Right)
        val isolated = group(listOf(innerRule), isolated = true)
        val outerParts = listOf(outer, isolated)
        val outerPreparation = NativeOrdinaryPreparation(outerParts)
        outerPreparation.resolveBodyLeading(outerParts, 100)
        assertFalse(outerPreparation.hasClearance(innerRule))
        assertEquals(listOf(1), measured)

        val localMeasured = mutableListOf<Int>()
        val innerFloat = floated(2, TableFloatSide.Right, 25f, localMeasured)
        val innerParts = listOf(innerFloat, innerRule)
        val localPreparation = NativeOrdinaryPreparation(innerParts)
        localPreparation.resolveBodyLeading(innerParts, 100)
        assertTrue(localPreparation.hasClearance(innerRule))
        assertEquals(listOf(2), localMeasured)
        assertFalse(outerPreparation.hasClearance(innerRule))

        val ordinaryRule = rule(FigureClear.Right)
        val ordinary = group(listOf(ordinaryRule), isolated = false)
        val ordinaryParts = listOf(floated(3, TableFloatSide.Right, 100f, mutableListOf()), ordinary)
        val ordinaryPreparation = NativeOrdinaryPreparation(ordinaryParts)
        ordinaryPreparation.resolveBodyLeading(ordinaryParts, 100)
        assertTrue(ordinaryPreparation.hasClearance(ordinaryRule))
        assertFalse(profile(ordinaryRule, ordinaryPreparation).beforeAdjoins)
    }
}
