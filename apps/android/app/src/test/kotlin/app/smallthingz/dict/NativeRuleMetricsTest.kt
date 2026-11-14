package app.smallthingz.dict

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class NativeRuleMetricsTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun em(value: Float) = StyleLength(StyleLengthUnit.Em, value)
    private fun edges(top: StyleLength = px(0f), right: StyleLength = px(0f),
        bottom: StyleLength = px(0f), left: StyleLength = px(0f)) = StyleEdges(top, right, bottom, left)
    private fun style(height: StyleLength = px(1f), fill: ContainerColor = ContainerColor.Rgb("#102030"),
        margins: StyleEdges = edges()) = RuleStyle(height, fill, margins)
    private fun resolve(style: RuleStyle, density: Float = 1f, body: Float = 16f, dark: Boolean = false) =
        resolveAuthoredRuleMetrics(style, density, body, dark)
    private fun unavailable(block: () -> Unit) {
        try { block(); fail("Expected an explicit native geometry refusal") }
        catch (_: UnsupportedFloatLayout) { }
    }

    @Test fun unitsUseDensityOrIndependentBodyExactlyOnce() {
        val result = resolve(style(em(.125f), margins = edges(em(.5f), px(.25f), em(.25f), px(.5f))),
            density = 1.5f, body = 20f)
        assertEquals(2.5f, result.height, 0f)
        assertEquals(10f, result.margins.top, 0f)
        assertEquals(.375f, result.margins.right, 0f)
        assertEquals(5f, result.margins.bottom, 0f)
        assertEquals(.75f, result.margins.left, 0f)
        assertEquals(38.875f, result.contentWidth(40f), 0f)
        assertEquals(39, result.allocatedWidth(40f))
    }

    @Test fun fractionalHeightHasOnlyAnIntegerAllocationCeiling() {
        val result = resolve(style(px(.25f)), density = 1.5f)
        assertEquals(.375f, result.height, 0f)
        assertEquals(1, result.allocatedHeight)
        assertTrue(result.positive)
        assertFalse(result.adjoining.through)
        assertEquals(10.25f, result.contentWidth(10.25f), 0f)
        assertEquals(11, result.allocatedWidth(10.25f))
    }

    @Test fun emptyAutoWidthContributesOnlyFixedHorizontalMargins() {
        val source = style(px(20f), margins = edges(px(100f), px(.5f), px(200f), px(.25f)))
        val result = resolve(source)
        assertEquals(.75f, result.horizontalMargins, 0f)
        assertEquals(NativeWidthRange(1, 1), result.intrinsic())
        assertEquals(9.25f, result.contentWidth(10f), 0f)
        assertEquals(0f, result.contentWidth(.5f), 0f)
        assertEquals(0, result.allocatedWidth(0f))
        assertEquals(result.intrinsic(), resolve(source.copy(height = px(0f))).intrinsic())
        assertEquals(NativeWidthRange(0, 0), resolve(style(px(300f))).intrinsic())
    }

    @Test fun zeroHeightAndZeroBodyBasisHaveNoSeparatorOrTextMinimum() {
        val zero = resolve(style(px(0f), margins = edges(px(3f), px(2f), px(7f), px(4f))))
        assertEquals(0f, zero.height, 0f)
        assertEquals(0, zero.allocatedHeight)
        assertFalse(zero.positive)
        assertTrue(zero.adjoining.through)
        assertEquals(3f, zero.adjoining.before, 0f)
        assertEquals(7f, zero.adjoining.after, 0f)
        val zeroBasis = resolve(style(em(2f), margins = edges(em(1f), px(2f), em(3f), px(4f))), body = 0f)
        assertEquals(0f, zeroBasis.height, 0f)
        assertEquals(0f, zeroBasis.margins.top, 0f)
        assertEquals(0f, zeroBasis.margins.bottom, 0f)
        assertEquals(6f, zeroBasis.horizontalMargins, 0f)
        assertTrue(zeroBasis.adjoining.through)
    }

    @Test fun allocationCeilingsPreserveSubUlpRemaindersAtIntegerBoundaries() {
        val tiny = Float.fromBits((127 - 25) shl 23)
        val intrinsic = resolve(style(margins = edges(left = px(1f), right = px(tiny))))
        assertEquals(1f, intrinsic.horizontalMargins, 0f)
        assertEquals(NativeWidthRange(2, 2), intrinsic.intrinsic())
        val justBelowOne = Float.fromBits(1f.toRawBits() - 1)
        val allocated = resolve(style(margins = edges(left = px(justBelowOne))))
        assertEquals(1f, allocated.contentWidth(2f), 0f)
        assertEquals(2, allocated.allocatedWidth(2f))
    }

    @Test fun zeroRuleAdjoinsThroughButFractionalPositiveRuleSeparatesSiblingSets() {
        fun followingTop(rule: NativeRuleMetrics): Pair<Float, Float> {
            val cursor = NativeMarginCursor(NativeMarginCollapse(false, false))
            val before = NativeAdjoiningMargins(0f, 12f, false)
            val beforePlacement = cursor.begin(before)
            cursor.end(beforePlacement, 5f, before)
            val rulePlacement = cursor.begin(rule.adjoining)
            cursor.end(rulePlacement, rule.height, rule.adjoining)
            val after = NativeAdjoiningMargins(8f, 0f, false)
            val afterPlacement = cursor.begin(after)
            cursor.end(afterPlacement, 7f, after)
            return afterPlacement.borderTop to cursor.finish()
        }
        val source = style(px(0f), margins = edges(top = px(4f), bottom = px(20f)))
        assertEquals(25f to 32f, followingTop(resolve(source)))
        assertEquals(37.5f to 44.5f, followingTop(resolve(source.copy(height = px(.5f)))))
        val through = NativeAdjoiningMargins.sequence(listOf(resolve(source).adjoining))
        assertEquals(20f, through.before, 0f)
        assertEquals(20f, through.after, 0f)
        assertTrue(through.through)
    }

    @Test fun transparentFillDoesNotErasePositiveGeometryOrChangeCollapse() {
        val clear = resolve(style(fill = ContainerColor.Transparent))
        val ink = resolve(style())
        assertEquals(null, clear.fill)
        assertEquals(0xff102030.toInt(), checkNotNull(ink.fill))
        assertEquals(ink.height, clear.height, 0f)
        assertEquals(ink.adjoining, clear.adjoining)
        assertEquals(ink.contentWidth(100f), clear.contentWidth(100f), 0f)
        assertTrue(clear.positive)
    }

    @Test fun sourceLightDarkColorsResolveWithoutGeometryChanges() {
        val source = style(fill = ContainerColor.LightDark("#123456", "#abcdef"))
        val light = resolve(source)
        val dark = resolve(source, dark = true)
        assertEquals(0xff123456.toInt(), checkNotNull(light.fill))
        assertEquals(0xffabcdef.toInt(), checkNotNull(dark.fill))
        assertEquals(light.copy(fill = dark.fill), dark)
    }

    @Test fun nativeBoundsAndTruePositiveUnderflowRefuseInsteadOfClamping() {
        unavailable { resolve(style(px(TablePixelLimit.toFloat())), density = 2f) }
        unavailable { resolve(style(em(2f)), body = TablePixelLimit.toFloat()) }
        unavailable { resolve(style(margins = edges(left = px(TablePixelLimit.toFloat()), right = px(1f)))) }
        unavailable { resolve(style(px(Float.MIN_VALUE)), density = Float.MIN_VALUE) }
        val result = resolve(style())
        unavailable { result.contentWidth(Float.NaN) }
        unavailable { result.contentWidth(-1f) }
        unavailable { result.contentWidth(TablePixelLimit + 1f) }
        assertEquals(TablePixelLimit, resolve(style(px(TablePixelLimit.toFloat()))).allocatedHeight)
    }
}
