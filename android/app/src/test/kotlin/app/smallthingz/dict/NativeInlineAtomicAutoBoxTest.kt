package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativeInlineAtomicAutoBoxTest {
    private val padding = NativeInlineBoxEdges(.25f, 1.5f, .75f, 2.25f)
    private val border = NativeInlineBoxEdges(.5f, .25f, 1.25f, .75f)
    private val margins = NativeInlineBoxEdges(.75f, 4.5f, 1.25f, 2.5f)

    @Test fun autoContentBoxUsesContainingWidthAndCapWithoutRescalingEdges() {
        // Independent arithmetic: horizontal edges=4.75, margins=7, hence C40.75
        // leaves29 content. Prior inline text is deliberately not an input here.
        val widths = nativeInlineAtomicAutoWidths(12.5f, 85.25f, 70f, padding, border, ContainerBoxSizing.ContentBox)
        assertEquals(12.5f, widths.minimum, 0f); assertEquals(70f, widths.maximum, 0f)
        assertEquals(29f, nativeInlineAtomicAutoContentWidth(widths, 40.75f, padding, border, margins), 0f)
        assertEquals(12.5f, nativeInlineAtomicAutoContentWidth(widths, 5f, padding, border, margins), 0f)
        assertEquals(70f, nativeInlineAtomicAutoContentWidth(widths, 1000f, padding, border, margins), 0f)
        val used = nativeInlineAtomicAutoAllocation(29f, 12.375f, padding, border, margins)
        assertEquals(33.75f, used.borderWidth, 0f); assertEquals(40.75f, used.marginWidth, 0f)
        assertEquals(15.125f, used.borderHeight, 0f); assertEquals(17.125f, used.marginHeight, 0f)
        assertEquals(5.5f, used.contentLeft, 0f); assertEquals(1.5f, used.contentTop, 0f)
        assertEquals(2.5f, used.borderLeft, 0f); assertEquals(.75f, used.borderTop, 0f)
        val cappedBorder = nativeInlineAtomicAutoWidths(12.5f, 85.25f, 70f, padding, border, ContainerBoxSizing.BorderBox)
        assertEquals(65.25f, cappedBorder.maximum, 0f)
        val baseline = nativeInlineAtomicBoxBaseline(used, 13.125f)
        assertEquals(14.625f, baseline.baselineFromMarginTop, 0f)
        assertEquals(-14.625f, baseline.metrics.top, 0f); assertEquals(2.5f, baseline.metrics.bottom, 0f)
        // Large intrinsic MAX may exceed a local coordinate budget while a real max
        // cap remains representable; no synthetic large used box is allocated.
        val huge = nativeInlineAtomicAutoWidths(12.5f, Float.MAX_VALUE, 70f, padding, border, ContainerBoxSizing.ContentBox)
        assertEquals(widths, huge)
    }

    @Test fun borderBoxCapKeepsZeroContentRealEdgesAndSignedLastBaseline() {
        val zero = nativeInlineAtomicAutoWidths(12.5f, 85.25f, 3f, padding, border, ContainerBoxSizing.BorderBox)
        assertEquals(0f, zero.minimum, 0f); assertEquals(0f, zero.maximum, 0f)
        val width = nativeInlineAtomicAutoContentWidth(zero, 80f, padding, border, margins)
        val used = nativeInlineAtomicAutoAllocation(width, 0f, padding, border, margins)
        assertEquals(0f, used.contentWidth, 0f); assertEquals(0f, used.contentHeight, 0f)
        assertEquals(4.75f, used.borderWidth, 0f); assertEquals(11.75f, used.marginWidth, 0f)
        assertEquals(2.75f, used.borderHeight, 0f); assertEquals(4.75f, used.marginHeight, 0f)
        val baseline = nativeInlineAtomicBoxBaseline(used, 5.5f)
        assertEquals(7f, baseline.baselineFromMarginTop, 0f)
        assertEquals(-7f, baseline.metrics.top, 0f); assertEquals(-2.25f, baseline.metrics.bottom, 0f)
        fun rejects(block: () -> Unit) {
            try { block(); fail("Invalid auto allocation must be explicit") }
            catch (_: UnsupportedFloatLayout) { }
        }
        rejects { nativeInlineAtomicAutoWidths(3f, 2f, 70f, padding, border, ContainerBoxSizing.ContentBox) }
        rejects { nativeInlineAtomicAutoWidths(1f, 2f, 0f, padding, border, ContainerBoxSizing.ContentBox) }
        rejects { nativeInlineAtomicAutoContentWidth(zero, Float.NaN, padding, border, margins) }
        rejects { nativeInlineAtomicAutoAllocation(0f, -1f, padding, border, margins) }
        assertEquals(4.75f, nativeInlineAtomicAutoAllocation(0f, 0f, padding, border, margins).borderWidth, 0f)
    }
}
