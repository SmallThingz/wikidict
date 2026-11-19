package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativeInlineIntrinsicLinesTest {
    @Test fun signedLengthsUseTheirOwnBasisAndOnlyBottomMarginChangesOuterHeight() {
        val em = nativeInlineIntrinsicSignedLength(InlineBoxSignedLength(StyleLengthUnit.Em, -.3f), 15f, 2f)
        val px = nativeInlineIntrinsicSignedLength(InlineBoxSignedLength(StyleLengthUnit.Px, -.3f), 15f, 2f)
        assertEquals(-4.5f, em, .00001f); assertEquals(-.6f, px, .00001f)
        val allocation = nativeInlineIntrinsicLinesAllocation(7.125f, 30f, em)
        assertEquals(7.125f, allocation.contentWidth, 0f)
        assertEquals(7.125f, allocation.marginWidth, 0f)
        assertEquals(30f, allocation.contentHeight, 0f)
        assertEquals(30f, allocation.borderHeight, 0f)
        assertEquals(25.5f, allocation.marginHeight, 0f)
        val lowered = nativeInlineIntrinsicLinesBaseline(allocation, 26f, -6f)
        assertEquals(20f, lowered.baselineFromMarginTop, 0f)
        assertEquals(-20f, lowered.metrics.top, 0f)
        assertEquals(5.5f, lowered.metrics.bottom, 0f)
        val raised = nativeInlineIntrinsicLinesBaseline(allocation, 26f, 6f)
        assertEquals(-32f, raised.metrics.top, 0f)
        assertEquals(-6.5f, raised.metrics.bottom, 0f)
        // Signed descent is legitimate; a negative margin never erases content.
        assertEquals(25.5f, raised.metrics.height, 0f)
        assertEquals(30f, allocation.contentHeight, 0f)
        val zero = nativeInlineIntrinsicLinesAllocation(7.125f, 30f, 0f)
        assertEquals(nativeInlineAtomicBoxBaseline(zero, 26f),
            nativeInlineIntrinsicLinesBaseline(zero, 26f, 0f))
    }

    @Test fun nativeBoundsRefuseInvertedOrUnrepresentableSignedEnvelopesWithoutClamping() {
        fun rejects(block: () -> Unit) {
            try { block(); fail("Unrepresentable intrinsic geometry must remain explicit") }
            catch (_: UnsupportedFloatLayout) { }
        }
        rejects { nativeInlineIntrinsicLinesAllocation(4f, 12f, -12.125f) }
        rejects { nativeInlineIntrinsicLinesAllocation(4f, 0f, 0f) }
        rejects { nativeInlineIntrinsicLinesAllocation(4f, 12f, Float.POSITIVE_INFINITY) }
        rejects { nativeInlineIntrinsicSignedLength(InlineBoxSignedLength(StyleLengthUnit.Em, Float.MAX_VALUE), 15f, 1f) }
        val zeroOuter = nativeInlineIntrinsicLinesAllocation(4f, 12f, -12f)
        assertEquals(12f, zeroOuter.contentHeight, 0f)
        assertEquals(0f, zeroOuter.marginHeight, 0f)
        val metrics = nativeInlineIntrinsicLinesBaseline(zeroOuter, 10f, -3f).metrics
        assertEquals(-7f, metrics.top, 0f); assertEquals(-7f, metrics.bottom, 0f)
        val limit = nativeInlineIntrinsicLinesAllocation(4f, 12f, 0f)
        rejects { nativeInlineIntrinsicLinesBaseline(limit, TablePixelLimit.toFloat(), 1f) }
        val recovered = nativeInlineIntrinsicLinesAllocation(4f, 12f, -3f)
        assertEquals(9f, recovered.marginHeight, 0f)
        assertEquals(12f, recovered.contentHeight, 0f)
    }
}
