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
    @Test fun ordinaryAbsolutePositionsUseGenericCssAxesAndRetainOwnNonzeroBoxes() {
        val position = ContainerAbsolutePosition(SignedContainerMargin(StyleLengthUnit.Em, -.5f),
            SignedContainerMargin(StyleLengthUnit.Px, 3f))
        val placement = nativeOrdinaryAbsolutePosition(position, 41, 1.25f, 24f)
        assertEquals(41, placement.containingBlockId)
        assertEquals(-12f, placement.left, 0f); assertEquals(3.75f, placement.top, 0f)
        val style = ContainerStyle(
            width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 120.25f)), height = px(20f),
            ownerFont = InlineFontSnapshot(18f, FontScaleBasis.CssPx, fontNormalized = true),
            lineHeight = ContainerLineHeight.Length(px(20f)), textAlign = CellTextAlign.Right,
            textWrap = TextWrap.NoWrap, absolutePosition = position)
        val span = Span("link", "Original label", "Exact target", targetFragment = "Exact_fragment",
            bold = false, italic = false, fontScale = 18f, fontScaleBasis = FontScaleBasis.CssPx)
        val prepared = PreparedNativeFloatText(span.text, null, Any(), null, menu = {}, fallback = {})
        val text = NativeFloatContextSpec.Text(prepared, 0f, "source/relative/static/absolute/paragraph")
        val spec = nativeContainerSpec(42, style.atViewport(640.0), listOf(text),
            1.25f, 24f, false, false, false, absolutePosition = placement)
        assertNull(spec.unavailableReason); assertNull(spec.absolute); assertNull(spec.scrollport)
        assertSame(placement, spec.absolutePosition)
        assertFalse(spec.relativeAuto); assertNull(spec.absoluteContainingBlock)
        assertEquals(25f, checkNotNull(spec.fixedContentHeight), 0f)
        val intrinsic = ContainerWidths(999f, 999f)
        assertEquals(150, spec.contentWidth(400, intrinsic))
        // The Float allocation is retained independently of the legacy integer measurement adapter.
        assertEquals(150.3125f, checkNotNull(spec.horizontal).invoke(400, intrinsic).content, 0f)
        assertSame(text, spec.preparedParts!!.single()); assertSame(prepared, text.prepared)
        assertEquals("Exact target", span.target); assertEquals("Exact_fragment", span.targetFragment)
        assertEquals(18f, style.ownerFont!!.fontScale!!, 0f)
        assertEquals(ContainerLineHeight.Length(px(20f)), style.lineHeight)
        assertEquals(TextWrap.NoWrap, style.textWrap)
        val missingAnchor = nativeContainerSpec(42, style.atViewport(640.0), listOf(text),
            1.25f, 24f, false, false, false)
        assertEquals("Absolute positioned content requires its nearest relative Container", missingAnchor.unavailableReason)
        assertSame(text, missingAnchor.preparedParts!!.single())
        assertNull(missingAnchor.absolutePosition)
        val zero = nativeContainerSpec(42, style.copy(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 0f)),
            height = px(0f)).atViewport(640.0), listOf(text), 1.25f, 24f, false, false, false,
            absolutePosition = placement)
        assertNull(zero.unavailableReason); assertEquals(0f, checkNotNull(zero.fixedContentHeight), 0f)
        assertEquals(0f, checkNotNull(zero.horizontal).invoke(400, intrinsic).content, 0f)
        assertSame(text, zero.preparedParts!!.single())
        val changedBody = nativeOrdinaryAbsolutePosition(position, 41, 1.25f, 48f)
        assertEquals(-24f, changedBody.left, 0f); assertEquals(placement.top, changedBody.top, 0f)
        assertEquals(0f, nativeOrdinaryAbsolutePosition(position, 41, 1.25f, 0f).left, 0f)
        val tooLarge = position.copy(left = SignedContainerMargin(StyleLengthUnit.Px, Float.MAX_VALUE))
        assertTrue(runCatching { nativeOrdinaryAbsolutePosition(tooLarge, 41, 2f, 24f) }.exceptionOrNull()
            is UnsupportedFloatLayout)
        for (density in listOf(0f, Float.NaN, Float.POSITIVE_INFINITY))
            assertTrue(runCatching { nativeOrdinaryAbsolutePosition(position, 41, density, 24f) }.isFailure)
        assertEquals(-.5f, position.left.value, 0f); assertEquals(3f, position.top.value, 0f)

        val delegated = NativeFloatContextSpec.Child(50, { it }, 0f)
        val relative = ContainerStyle(positioning = ContainerPositioning.RelativeAuto, textWrap = TextWrap.NoWrap,
            padding = StyleEdges(px(4f), px(0f), px(0f), px(6f)),
            border = ContainerBorder.Solid(px(2f), ContainerColor.Transparent))
        val anchor = NativeAbsoluteContainingBlock(7.5f, 5f)
        val admitted = nativeContainerSpec(41, relative.atViewport(640.0), listOf(delegated, spec),
            1.25f, 24f, false, false, false, absoluteContainingBlock = anchor)
        assertNull(admitted.unavailableReason); assertSame(anchor, admitted.absoluteContainingBlock)
        assertTrue(admitted.relativeAuto); assertFalse(admitted.isolatesFloats)
        assertEquals(10f, admitted.padding(400).left, 0f); assertEquals(7.5f, admitted.padding(400).top, 0f)
        assertEquals(7.5f, anchor.paddingLeft, 0f); assertEquals(5f, anchor.paddingTop, 0f)
        assertEquals(listOf(delegated, spec), admitted.preparedParts)
        val legacy = nativeContainerSpec(41, ContainerStyle(positioning = ContainerPositioning.RelativeAuto)
            .atViewport(640.0), listOf(delegated), 1.25f, 24f, false, false, false)
        assertNotNull(legacy.unavailableReason); assertNull(legacy.absoluteContainingBlock)
        assertSame(delegated, legacy.preparedParts!!.single())
    }

}
