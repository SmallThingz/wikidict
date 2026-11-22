package app.smallthingz.dict

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/** Source-only controls; no Android font metrics or runtime result is inferred here. */
class NativeRubyMetricsTest {
    @Test fun shorterSpanningConstraintsPrecedeLongerOnesAndPartialOverlapsRetainBoth() {
        val short = NativeRubyWidthConstraint(0, 2, 50f)
        val long = NativeRubyWidthConstraint(0, 3, 90f)
        assertEquals(listOf(35f, 35f, 20f), nativeRubyColumnWidths(listOf(10f, 10f, 10f),
            listOf(0f, 0f, 0f), listOf(long, short)))
        assertEquals(nativeRubyColumnWidths(listOf(10f, 10f, 10f), listOf(0f, 0f, 0f), listOf(long, short)),
            nativeRubyColumnWidths(listOf(10f, 10f, 10f), listOf(0f, 0f, 0f), listOf(short, long)))
        val overlapping = nativeRubyColumnWidths(listOf(10f, 10f, 10f), listOf(0f, 0f, 0f),
            listOf(NativeRubyWidthConstraint(0, 2, 100f), NativeRubyWidthConstraint(1, 2, 100f)))
        assertEquals(listOf(50f, 70f, 30f), overlapping)
        assertEquals(150f, overlapping.sum(), 0f)
        assertEquals(100f, overlapping[1] + overlapping[2], 0f)
    }

    @Test fun annotationAllocationIncludesOnlyInteriorBaseGaps() {
        assertEquals(listOf(21f, 21f), nativeRubyColumnWidths(listOf(10f, 10f), listOf(99f, 8f),
            listOf(NativeRubyWidthConstraint(0, 2, 50f))))
        assertEquals(listOf(10f, 30f), nativeRubyColumnWidths(listOf(10f, 10f), listOf(99f, 8f),
            listOf(NativeRubyWidthConstraint(1, 1, 30f))))
        assertThrows(IllegalArgumentException::class.java) {
            nativeRubyColumnWidths(listOf(10f), listOf(0f), listOf(NativeRubyWidthConstraint(0, 2, 30f)))
        }
    }

    @Test fun additionalLeadingMeetsThreeContainerSeparationWithoutChangingBaseAlignment() {
        val base = NativeUsedLineMetrics(0f, 0f)
        val container = NativeUsedLineMetrics(-20f, 10f)
        val above = nativeRubyAdditionalLeading(base, container, above = true, below = false)
        assertEquals(NativeUsedLineMetrics(-30f, 0f), above)
        assertEquals(30f, above.height, 0f)
        // The complete container can overflow its line box; base baseline zero stays zero.
        assertEquals(10f, container.bottom - above.bottom, 0f)
        for (baseline in listOf(-above.height, 0f, above.height)) {
            assertEquals(30f, (container.bottom + baseline) - (container.top + baseline), 0f)
        }
        assertEquals(container.bottom, container.top + above.height, 0f)
        assertEquals(NativeUsedLineMetrics(-20f, 10f),
            nativeRubyAdditionalLeading(base, container, above = true, below = true))
        assertEquals(NativeUsedLineMetrics(0f, 30f),
            nativeRubyAdditionalLeading(base, container, above = false, below = true))
        val roomy = NativeUsedLineMetrics(-24f, 24f)
        assertEquals(roomy, nativeRubyAdditionalLeading(roomy, container, above = true, below = true))
    }

    @Test fun noVisibleAnnotationKeepsShortBaseMetricsAndIntactRowsCenterWithoutInventedOpportunities() {
        val base = NativeUsedLineMetrics(2f, 2f)
        assertEquals(base, nativeRubyAdditionalLeading(base, NativeUsedLineMetrics(-20f, 20f),
            above = false, below = false))
        assertEquals(NativeRubyAroundSpacing(5f, 10f), nativeRubyAroundSpacing(20f, 30f, 0))
        assertEquals(NativeRubyAroundSpacing(1f, 2f), nativeRubyAroundSpacing(20f, 26f, 2))
        assertEquals(NativeRubyAroundSpacing(0f, 0f), nativeRubyAroundSpacing(20f, 20f, 2))
    }

    @Test fun numericLocalShiftNeverCancelsAnAncestorAndRepeatedScriptDisplacementIsAppliedOnce() {
        val root = NativeRubyScriptState()
        val normal = NativeRubyScriptMode.Normal
        val sup = NativeRubyScriptMode.Super
        val owner = nativeRubyBaselinePlacement(normal, 0f, .25f, root)
        assertEquals(.25f, owner.local + nativeRubyBaselinePlacement(normal, 0f, null, owner.state).local, 0f)
        assertEquals(.25f, owner.local + nativeRubyBaselinePlacement(normal, 0f, 0f, owner.state).local, 0f)
        assertEquals(1f, owner.local + nativeRubyBaselinePlacement(normal, 0f, .75f, owner.state).local, 0f)
        val scriptOwner = nativeRubyBaselinePlacement(sup, -8f, null, root)
        // Changing only the descendant font must not reapply its different native default.
        assertEquals(-8f, scriptOwner.local + nativeRubyBaselinePlacement(sup, -4f, null, scriptOwner.state).local, 0f)
        assertEquals(0f, scriptOwner.local + nativeRubyBaselinePlacement(normal, 0f, null, scriptOwner.state).local, 0f)
        val numericSup = nativeRubyBaselinePlacement(sup, -8f, .25f, root)
        assertEquals(.25f, numericSup.local, 0f)
        assertEquals(0f, numericSup.state.applied, 0f)
        assertEquals(.25f, numericSup.local + nativeRubyBaselinePlacement(sup, -4f, null, numericSup.state).local, 0f)
        assertEquals(.25f, numericSup.local + nativeRubyBaselinePlacement(normal, 0f, null, numericSup.state).local, 0f)
        assertEquals(.25f, numericSup.local + nativeRubyBaselinePlacement(sup, -4f, 0f, numericSup.state).local, 0f)
        assertEquals(1f, numericSup.local + nativeRubyBaselinePlacement(sup, -4f, .75f, numericSup.state).local, 0f)
        assertThrows(IllegalArgumentException::class.java) { nativeRubyBaselinePlacement(sup, Float.NaN, null, root) }
    }

    @Test fun atomicInlineBoxUsesFractionalPhysicalBoxesAndLastLineBaselineBeyondItsHeight() {
        // Independent scalar geometry only: these values are not Android font metrics.
        val padding = NativeInlineBoxEdges(1.25f, 2.5f, .75f, .5f)
        val border = NativeInlineBoxEdges(.5f, .75f, 1.25f, .25f)
        val margins = NativeInlineBoxEdges(3f, 4f, 5f, 6f)
        val content = nativeInlineAtomicBoxAllocation(10.25f, 5.5f, padding, border, margins,
            ContainerBoxSizing.ContentBox)
        assertEquals(NativeInlineAtomicBoxAllocation(contentWidth = 10.25f, contentHeight = 5.5f,
            borderWidth = 14.25f, borderHeight = 9.25f, marginWidth = 24.25f, marginHeight = 17.25f,
            contentLeft = 6.75f, contentTop = 4.75f, borderLeft = 6f, borderTop = 3f), content)
        val borderSized = nativeInlineAtomicBoxAllocation(14.25f, 9.25f, padding, border, margins,
            ContainerBoxSizing.BorderBox)
        assertEquals(content, borderSized)
        val oneLine = nativeInlineAtomicBoxBaseline(content, 4f)
        assertEquals(8.75f, oneLine.baselineFromMarginTop, 0f)
        assertEquals(NativeUsedLineMetrics(-8.75f, 8.5f), oneLine.metrics)
        // A real later inner line can lie below the definite content height. Moving its
        // baseline changes the parent-relative top/bottom, never the atom's advance/height.
        val laterLine = nativeInlineAtomicBoxBaseline(content, 20f)
        assertEquals(24.75f, laterLine.baselineFromMarginTop, 0f)
        assertEquals(NativeUsedLineMetrics(-24.75f, -7.5f), laterLine.metrics)
        assertEquals(17.25f, laterLine.metrics.bottom - laterLine.metrics.top, 0f)
        assertEquals(24.25f, content.marginWidth, 0f)
        assertEquals(9.25f, content.borderHeight, 0f)
    }

    @Test fun atomicBorderBoxFloorsOnlyContentAndRejectsNonfiniteOrUnrepresentableGeometry() {
        val padding = NativeInlineBoxEdges(1.25f, 2.5f, .75f, .5f)
        val border = NativeInlineBoxEdges(.5f, .75f, 1.25f, .25f)
        val margins = NativeInlineBoxEdges(3f, 4f, 5f, 6f)
        val minimum = nativeInlineAtomicBoxAllocation(.5f, .25f, padding, border, margins,
            ContainerBoxSizing.BorderBox)
        assertEquals(NativeInlineAtomicBoxAllocation(contentWidth = 0f, contentHeight = 0f,
            borderWidth = 4f, borderHeight = 3.75f, marginWidth = 14f, marginHeight = 11.75f,
            contentLeft = 6.75f, contentTop = 4.75f, borderLeft = 6f, borderTop = 3f), minimum)
        assertEquals(NativeUsedLineMetrics(-8.75f, 3f), nativeInlineAtomicBoxBaseline(minimum, 4f).metrics)
        for (invalid in listOf(0f, -1f, Float.NaN, Float.POSITIVE_INFINITY, Float.MAX_VALUE)) {
            assertThrows(UnsupportedFloatLayout::class.java) {
                nativeInlineAtomicBoxAllocation(invalid, 1f, padding, border, margins, ContainerBoxSizing.ContentBox)
            }
            assertThrows(UnsupportedFloatLayout::class.java) {
                nativeInlineAtomicBoxAllocation(1f, invalid, padding, border, margins, ContainerBoxSizing.ContentBox)
            }
        }
        assertThrows(UnsupportedFloatLayout::class.java) { nativeInlineAtomicBoxBaseline(minimum, Float.NaN) }
        assertThrows(UnsupportedFloatLayout::class.java) { nativeInlineAtomicBoxBaseline(minimum, Float.MAX_VALUE) }
    }
}
