package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Structural controls only: native Canvas/TextPaint geometry is covered by the device source. */
class NativeAuthoredRuleFlowTest {
    private fun rule(height: Float, top: Float = 0f, bottom: Float = 0f) =
        NativeFloatContextPart.Rule(1, NativeRuleMetrics(height, 0xff000000.toInt(),
            FloatMargins(top, 0f, bottom, 0f)))
    private fun profile(part: NativeFloatContextPart) = checkNotNull(NativeFloatContextGeometry.adjoiningProfile(part))
    private fun group(children: List<NativeFloatContextPart>, padding: Float = 0f,
        top: Float = 0f, bottom: Float = 0f) = NativeFloatContextPart.Container(2, 100,
        { _, _ -> error("A structural margin query must not measure a child") },
        margins = FloatMargins(top, 0f, bottom, 0f), padding = FloatMargins(padding, 0f, padding, 0f),
        preparedParts = children)
    private fun paragraph(gap: Float = 0f) = NativeFloatContextPart.Text("catlinks",
        { _, _ -> error("A structural margin query must not shape text") }, gapAfter = gap)

    @Test fun positiveRuleAdvancesByExactHeightAndAdjoinsItsSiblingMargins() {
        val cursor = NativeMarginCursor(NativeMarginCollapse(false, false))
        val first = profile(rule(.25f, 3.125f, 7.5f))
        val firstPlacement = cursor.begin(first)
        assertEquals(3.125f, firstPlacement.borderTop, 0f)
        cursor.end(firstPlacement, .25f, first)
        val next = profile(rule(.75f, 5.25f, 2.5f))
        val nextPlacement = cursor.begin(next)
        assertEquals(10.875f, nextPlacement.borderTop, 0f)
        cursor.end(nextPlacement, .75f, next)
        assertEquals(14.125f, cursor.finish(), 0f)
        assertFalse(first.through)
    }

    @Test fun zeroRuleCarriesOneAdjoiningSetButPositiveRuleSeparatesItsEdges() {
        fun nextTop(height: Float): Float {
            val cursor = NativeMarginCursor(NativeMarginCollapse(false, false))
            val previous = NativeAdjoiningMargins(0f, 4f, false)
            cursor.end(cursor.begin(previous), 10f, previous)
            val middle = profile(rule(height, 7f, 11f))
            cursor.end(cursor.begin(middle), height, middle)
            return cursor.begin(NativeAdjoiningMargins(8f, 0f, false)).borderTop
        }
        assertTrue(profile(rule(0f, 7f, 11f)).through)
        assertEquals(21f, nextTop(0f), 0f)
        assertEquals(28.25f, nextTop(.25f), 0f)
    }

    @Test fun navContentPaddingKeepsRuleEdgesInsideItsOriginalContainer() {
        val sourceRule = rule(1f, 3.2f, 3.2f)
        val content = group(listOf(sourceRule, paragraph()), padding = 8f)
        val combined = profile(content)
        assertEquals(0f, combined.before, 0f)
        assertEquals(0f, combined.after, 0f)
        assertFalse(combined.through)
        assertEquals(NativeMarginCollapse(false, false), content.childCollapse(
            NativeFloatContextGeometry.adjoiningMarginsFor(content.preparedParts!!)))
        assertEquals(3.2f, profile(sourceRule).before, 0f)
        assertEquals(3.2f, profile(sourceRule).after, 0f)
    }

    @Test fun zeroRuleRetainsItsThroughProfileAcrossUnpaddedGroups() {
        val zero = rule(0f, 7f, 11f)
        val inner = group(listOf(zero), top = 3f, bottom = 5f)
        val outer = group(listOf(inner), top = 2f, bottom = 4f)
        val actual = profile(outer)
        assertTrue(actual.through)
        assertEquals(11f, actual.before, 0f)
        assertEquals(11f, actual.after, 0f)
        assertFalse(profile(group(listOf(rule(.25f, 7f, 11f)))).through)
    }

    @Test fun authoredRuleDoesNotAuthorizeImplicitLegacyGapsOrUnownedMargins() {
        assertThrows(UnsupportedFloatLayout::class.java) {
            NativeFloatContextGeometry.adjoiningMarginsFor(listOf(rule(1f), paragraph(6f)))
        }
        val legacyChild = NativeFloatContextPart.Child(3, NativeBlockWidth.FixedPx(100f),
            { error("A structural query must not measure the legacy child") }, gapAfter = 4f)
        assertThrows(UnsupportedFloatLayout::class.java) { profile(legacyChild) }
        assertThrows(UnsupportedFloatLayout::class.java) {
            NativeFloatContextGeometry.build(100, listOf(rule(1f)), adjoining = false)
        }
        assertEquals(NativeAdjoiningMargins(0f, 0f, false), profile(paragraph()))
    }
}
