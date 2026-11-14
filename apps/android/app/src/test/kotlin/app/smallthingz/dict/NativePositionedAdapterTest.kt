package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Constructed ownership controls, independent of EN source issuance and native rendering. */
class NativePositionedAdapterTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun scope() = PositionedScope(TextWrap.NoWrap, PositionedOverflowX.Scroll, PositionedOverflowY.Auto,
        listOf(PositionedViewportState(900, PositionedOverflowX.Hidden, PositionedOverflowY.Auto)))

    @Test fun responsiveAxisUsesExactRootViewportAndRejectsUnknownCoordinates() {
        val policy = scope()
        assertEquals(PositionedOverflowX.Scroll, positionedOverflowAt(policy, 0.0))
        assertEquals(PositionedOverflowX.Scroll, positionedOverflowAt(policy, 899.999999))
        assertEquals(PositionedOverflowX.Hidden, positionedOverflowAt(policy, 900.0))
        assertEquals(PositionedOverflowX.Hidden, positionedOverflowAt(policy, 900.000001))
        val large = policy.copy(viewportStates = listOf(
            PositionedViewportState(4294967295L, PositionedOverflowX.Hidden, PositionedOverflowY.Auto)))
        assertEquals(PositionedOverflowX.Scroll, positionedOverflowAt(large, 4294967294.999))
        assertEquals(PositionedOverflowX.Hidden, positionedOverflowAt(large, 4294967295.0))
        for (invalid in listOf(-.01, Double.NaN, Double.POSITIVE_INFINITY))
            assertTrue(runCatching { positionedOverflowAt(policy, invalid) }.isFailure)
    }

    @Test fun refusedScopeRetainsActualTextOwnersWithoutUnownedPositioningClaims() {
        val span = Span("link", "Retained label", "Exact target", targetFragment = "Exact_fragment")
        val paragraph = Block("paragraph", 0, listOf(span))
        val absoluteStyle = ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Percent, 100f)),
            height = px(0f), positioning = ContainerPositioning.Absolute(px(3f), px(130f),
                InlineFontSnapshot(12f, FontScaleBasis.CssPx, language = "en"),
                InlineComputedLength(12f, FontScaleBasis.CssPx), TextWrap.NoWrap))
        val absoluteSource = Container(listOf(paragraph), absoluteStyle)
        val scopeStyle = ContainerStyle(positioning = ContainerPositioning.RelativeAuto,
            positionedScope = scope(), height = px(20f))
        val source = Container(listOf(Block("container", 0, emptyList(), container = absoluteSource)), scopeStyle)
        val prepared = PreparedNativeFloatText(span.text, null, Any(), null, menu = {}, fallback = {})
        val text = NativeFloatContextSpec.Text(prepared, 0f, "source/absolute/paragraph")
        val original = nativeContainerSpec(17, absoluteStyle.atViewport(899.5), listOf(text),
            1f, 20f, false, false, false, absolute = NativeAbsoluteTextPlacement(130f, 3f))
        assertNull(original.unavailableReason)
        assertEquals(0f, checkNotNull(original.fixedContentHeight), 0f)
        val unavailable = nativeContainerSpec(9, scopeStyle.atViewport(899.5), listOf(original),
            1f, 20f, false, false, false, positioned = NativePositionedScrollportPolicy(source, PositionedOverflowX.Scroll))
        assertNotNull(unavailable.unavailableReason)
        assertNull(unavailable.scrollport)
        val retained = unavailable.preparedParts!!.single() as NativeFloatContextSpec.Container
        assertEquals(original.id, retained.id)
        assertNull(retained.absolute)
        assertNull(retained.fixedContentHeight)
        assertFalse(retained.relativeAuto)
        assertSame(text, retained.preparedParts!!.single())
        assertSame(prepared, (retained.preparedParts!!.single() as NativeFloatContextSpec.Text).prepared)
        assertEquals(listOf(0, 1, 2), nativeContextPaintSequence(listOf(NativePaintOrderNode(0,
            children = listOf(NativePaintOrderNode(1, retained.relativeAuto,
                listOf(NativePaintOrderNode(2)), absolute = retained.absolute != null))))))
        assertEquals(NativeAbsoluteTextPlacement(130f, 3f), original.absolute)
        assertEquals(0f, checkNotNull(original.fixedContentHeight), 0f)
        assertSame(span, source.blocks.single().container!!.blocks.single().spans.single())
        assertEquals("Exact target", span.target)
        assertEquals("Exact_fragment", span.targetFragment)

        val legacy = nativeContainerSpec(3, ContainerStyle(positioning = ContainerPositioning.RelativeAuto)
            .atViewport(899.5), listOf(NativeFloatContextSpec.Child(21, { it }, 0f)),
            1f, 20f, false, false, false)
        assertNotNull(legacy.unavailableReason)
        assertEquals(21, (legacy.preparedParts!!.single() as NativeFloatContextSpec.Child).id)
    }
}
