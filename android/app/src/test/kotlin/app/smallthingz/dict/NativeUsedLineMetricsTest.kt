package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativeUsedLineMetricsTest {
    @Test fun zeroAndNegativeHalfLeadingKeepTheBaselineAndReplacedExtentDistinct() {
        val zero = nativeInlineLineMetrics(-16f, 4f, 0f)
        assertEquals(-6f, zero.top, 0f)
        assertEquals(-6f, zero.bottom, 0f)
        assertEquals(0f, zero.height, 0f)
        val short = nativeInlineLineMetrics(-16f, 4f, 8f)
        assertEquals(NativeUsedLineMetrics(-10f, -2f), short)
        assertEquals(NativeUsedLineMetrics(-21f, 9f), nativeInlineLineMetrics(-16f, 4f, 30f))
        assertEquals(NativeUsedLineMetrics(-50f, 10f), zero.including(NativeUsedLineMetrics(-50f, 10f)))
        assertEquals(NativeUsedLineMetrics(-11f, -11f), nativeInlineLineMetrics(-16f, 4f, 0f, -5f))
    }

    @Test fun inheritedMultiplierUsesDescendantFontWhileComputedLengthRetainsItsValue() {
        val multiplier = ContainerLineHeight.Multiplier(1.5f)
        val computed = ContainerLineHeight.Length(StyleLength(StyleLengthUnit.Px, 30f))
        val childHeight = containerLineHeightPixels(multiplier, 1f, 20f, 16f)!!
        val fixedHeight = containerLineHeightPixels(computed, 1f, 20f, 16f)!!
        assertEquals(24f, childHeight, 0f)
        assertEquals(30f, fixedHeight, 0f)
        val child = nativeInlineLineMetrics(-12.8f, 3.2f, childHeight)
        assertEquals(-16.8f, child.top, .0001f)
        assertEquals(7.2f, child.bottom, .0001f)
        val fixed = nativeInlineLineMetrics(-12.8f, 3.2f, fixedHeight)
        assertEquals(-19.8f, fixed.top, .0001f)
        assertEquals(10.2f, fixed.bottom, .0001f)
        assertEquals(NativeUsedLineMetrics(-21f, 10.2f),
            nativeInlineLineMetrics(-16f, 4f, 30f).including(fixed))
    }

    @Test fun publicationReusesOnlyMatchingInputsAndReplacesReadyWithActualFailure() {
        data class Key(val owner: Any, val width: Int, val fontRevision: Int,
            val exclusions: List<NativeFloatExclusion>)
        val owner = Any()
        val key = Key(owner, 0, 1, emptyList())
        val publication = NativeGeometryPublication<Key, NativeGeometryOutcome<Any>>()
        val child = Any()
        val extents = NativeGeometryExtents(0, 0f, NativeFloatBounds(-4f, -12f, 18f, 8f),
            NativeFloatBounds(-2f, -10f, 17f, 6f))
        val ready = NativeGeometryOutcome.Ready(child, extents)
        assertNull(publication.forInput(key))
        publication.select(key)
        assertTrue(publication.publish(publication.begin(key), ready))
        publication.select(key.copy())
        assertSame(ready, publication.forInput(key.copy())) // Cached Compose measure may return immediately.
        assertSame(child, (publication.forInput(key) as NativeGeometryOutcome.Ready<*>).geometry)
        assertEquals(-4f, ready.extents.ink!!.left, 0f)
        assertEquals(-12f, ready.extents.ink!!.top, 0f)
        assertNull(publication.forInput(key.copy(fontRevision = 2)))
        assertNull(publication.forInput(key.copy(exclusions = listOf(
            NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 10f, 20f))))))
        assertNull(publication.forInput(key.copy(owner = Any())))
        val failed = NativeGeometryOutcome.Unavailable("Actual same-child measurement failed")
        assertTrue(publication.publish(publication.begin(key), failed))
        assertSame(failed, publication.forInput(key))
        assertTrue(publication.publish(publication.begin(key), ready))
        publication.ownerDetached()
        assertNull(publication.forInput(key))
    }

    @Test fun actualMeasureEntryInvalidatesSameKeyAndReentrantCompletionsCannotResurrectIt() {
        val publication = NativeGeometryPublication<String, NativeGeometryOutcome<String>>()
        val extents = NativeGeometryExtents(0, 0f, NativeFloatBounds(-20f, -12f, 40f, 8f),
            NativeFloatBounds(-10f, -9f, 35f, 6f))
        val ready = NativeGeometryOutcome.Ready("original native geometry", extents)
        publication.select("owner-A")
        val first = publication.begin("owner-A")
        assertTrue(publication.publish(first, ready))
        publication.select("owner-A")
        assertSame(ready, publication.forInput("owner-A"))
        val failedAttempt = publication.begin("owner-A")
        assertNull(publication.forInput("owner-A"))
        val failure = NativeGeometryOutcome.Unavailable("actual child failure")
        assertTrue(publication.publish(failedAttempt, failure))
        assertSame(failure, publication.forInput("owner-A"))
        val reentrant = publication.begin("owner-A")
        publication.select("owner-B")
        publication.select("owner-A") // Same value again must not make an old in-flight callback current.
        assertFalse(publication.publish(reentrant, ready))
        val later = publication.begin("owner-A")
        publication.ownerDetached()
        assertFalse(publication.publish(later, ready))
        assertNull(publication.forInput("owner-A"))
    }
}
