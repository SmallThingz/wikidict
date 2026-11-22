package app.smallthingz.dict

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class NativeClippedSourceMapTest {
    private val before = NativeClippedSourceAffinity.Before
    private val after = NativeClippedSourceAffinity.After

    private fun invalid(work: () -> Unit) {
        try { work(); fail("Expected invalid source-map input") }
        catch (_: IllegalArgumentException) { }
    }

    @Test fun originalTooltipTextAndWhitespaceRemainWhileVisualSlicesAreExact() {
        val hidden = "Tooltip time to peak concentrations"
        val original = "before$hidden after"
        val first = "before".length
        val last = first + hidden.length
        val map = NativeClippedSourceMap(original, listOf(NativeClippedSourceRange(first, last)))
        assertSame(original, map.source)
        assertEquals("before after", map.visual)
        assertEquals(hidden, map.source.substring(first, last))
        assertEquals(first, map.toVisual(first + 8))
        assertEquals(first, map.toSource(first, before))
        assertEquals(last, map.toSource(first, after))
        assertEquals(listOf(
            NativeClippedVisibleRange(0, first, 0, first),
            NativeClippedVisibleRange(last, original.length, first, map.visual.length),
        ), map.visibleIntersections(0, original.length))
        assertEquals(listOf(
            NativeClippedVisibleRange(first - 2, first, first - 2, first),
            NativeClippedVisibleRange(last, last + 2, first, first + 2),
        ), map.visibleIntersections(first - 2, last + 2))
        assertTrue(map.visibleIntersections(first, last).isEmpty())
        assertTrue(map.visibleIntersections(first, first).isEmpty())
        for (slice in map.visibleIntersections(0, original.length)) {
            assertEquals(original.substring(slice.sourceStart, slice.sourceEnd),
                map.visual.substring(slice.visualStart, slice.visualEnd))
        }
        val whitespace = NativeClippedSourceMap("a   b", listOf(NativeClippedSourceRange(2, 3)))
        assertEquals("a  b", whitespace.visual)
        assertEquals("a   b", whitespace.source)
        assertEquals(" ", whitespace.source.substring(2, 3))
        assertEquals(2, whitespace.toSource(2, before))
        assertEquals(3, whitespace.toSource(2, after))
    }

    @Test fun adjacentAndEdgeOccurrencesRetainSeparateIndicesAtOneCollapsedPoint() {
        val map = NativeClippedSourceMap("aaXXYYbbZZ", listOf(
            NativeClippedSourceRange(2, 4), NativeClippedSourceRange(4, 6), NativeClippedSourceRange(8, 10)))
        assertEquals("aabb", map.visual)
        assertEquals(listOf(0, 1, 2, 2, 2, 2, 2, 3, 4, 4, 4), (0..10).map(map::toVisual))
        assertEquals(listOf(0, 1, 2, 7, 8), (0..4).map { map.toSource(it, before) })
        assertEquals(listOf(0, 1, 6, 7, 10), (0..4).map { map.toSource(it, after) })
        assertEquals(0, map.clippedRangeIndexAt(2))
        assertEquals(0, map.clippedRangeIndexAt(3))
        assertEquals(1, map.clippedRangeIndexAt(4))
        assertNull(map.clippedRangeIndexAt(6))
        assertEquals(2, map.clippedRangeIndexAt(8))
        assertNull(map.clippedRangeIndexAt(10))
        assertEquals(listOf(0, 1), map.clippedRangeIndicesIntersecting(3, 5))
        assertEquals(listOf(1), map.clippedRangeIndicesIntersecting(4, 6))
        assertTrue(map.clippedRangeIndicesIntersecting(4, 4).isEmpty())
        assertEquals(listOf(NativeClippedVisibleRange(1, 2, 1, 2), NativeClippedVisibleRange(6, 7, 2, 3)),
            map.visibleIntersections(1, 7))

        val all = NativeClippedSourceMap("  ", listOf(NativeClippedSourceRange(0, 1), NativeClippedSourceRange(1, 2)))
        assertEquals("", all.visual)
        assertEquals("  ", all.source)
        assertEquals(0, all.toSource(0, before)); assertEquals(2, all.toSource(0, after))
        assertEquals(listOf(0, 0, 0), (0..2).map(all::toVisual))
        assertEquals(listOf(0, 1), all.clippedRangeIndicesIntersecting(0, 2))
        assertTrue(all.visibleIntersections(0, 2).isEmpty())
        val leading = NativeClippedSourceMap("XXa", listOf(NativeClippedSourceRange(0, 2)))
        assertEquals("a", leading.visual)
        assertEquals(0, leading.toSource(0, before)); assertEquals(2, leading.toSource(0, after))
        assertEquals(3, leading.toSource(1, before)); assertEquals(3, leading.toSource(1, after))
        val empty = NativeClippedSourceMap("", emptyList())
        assertEquals("", empty.visual)
        assertEquals(0, empty.toVisual(0)); assertEquals(0, empty.toSource(0, before))
        assertEquals(0, empty.toSource(0, after)); assertNull(empty.clippedRangeIndexAt(0))
    }

    @Test fun surrogateUnitsRemainAddressableButRemovalCannotSplitOriginalPairs() {
        val original = "A\uD83D\uDE00goneB\uD801\uDC37C"
        val map = NativeClippedSourceMap(original, listOf(NativeClippedSourceRange(3, 7)))
        assertEquals("A\uD83D\uDE00B\uD801\uDC37C", map.visual)
        assertEquals(2, map.toVisual(2)); assertEquals(2, map.toSource(2, before))
        assertEquals(5, map.toVisual(9)); assertEquals(9, map.toSource(5, after))
        assertEquals(listOf(NativeClippedVisibleRange(2, 3, 2, 3), NativeClippedVisibleRange(7, 10, 3, 6)),
            map.visibleIntersections(2, 10))
        for (slice in map.visibleIntersections(2, 10)) {
            assertEquals(original.substring(slice.sourceStart, slice.sourceEnd),
                map.visual.substring(slice.visualStart, slice.visualEnd))
        }
        invalid { NativeClippedSourceMap(original, listOf(NativeClippedSourceRange(2, 3))) }
        invalid { NativeClippedSourceMap(original, listOf(NativeClippedSourceRange(1, 2))) }
        invalid { NativeClippedSourceMap(original, listOf(NativeClippedSourceRange(8, 9))) }
        val wholePair = NativeClippedSourceMap(original, listOf(NativeClippedSourceRange(1, 3)))
        assertEquals("AgoneB\uD801\uDC37C", wholePair.visual)
        assertEquals(1, wholePair.toVisual(2))
        assertEquals(1, wholePair.toSource(1, before)); assertEquals(3, wholePair.toSource(1, after))

        invalid { NativeClippedSourceRange(1, 1) }
        invalid { NativeClippedSourceRange(-1, 1) }
        invalid { NativeClippedSourceMap("abcd", listOf(NativeClippedSourceRange(2, 3), NativeClippedSourceRange(0, 1))) }
        invalid { NativeClippedSourceMap("abcd", listOf(NativeClippedSourceRange(0, 3), NativeClippedSourceRange(2, 4))) }
        invalid { NativeClippedSourceMap("abcd", listOf(NativeClippedSourceRange(1, 5))) }
        invalid { map.toVisual(-1) }; invalid { map.toVisual(original.length + 1) }
        invalid { map.toSource(map.visual.length + 1, after) }
        invalid { map.visibleIntersections(4, 3) }
        invalid { map.clippedRangeIndicesIntersecting(0, original.length + 1) }
        invalid { map.clippedRangeIndexAt(-1) }
    }

    @Test fun snapshotUsesOccurrenceOffsetsAndDoesNotInventNativeCursorChoices() {
        val original = "sameXsameXsame"
        val input = mutableListOf(NativeClippedSourceRange(0, 4), NativeClippedSourceRange(5, 9))
        val map = NativeClippedSourceMap(original, input)
        input.clear(); input += NativeClippedSourceRange(10, 14)
        assertEquals("XXsame", map.visual)
        assertEquals(listOf(NativeClippedSourceRange(0, 4), NativeClippedSourceRange(5, 9)), map.clippedRanges)
        assertEquals(0, map.clippedRangeIndexAt(1)); assertEquals(1, map.clippedRangeIndexAt(6))
        assertNull(map.clippedRangeIndexAt(11))
        assertEquals(0, map.toSource(0, before)); assertEquals(4, map.toSource(0, after))
        assertEquals(5, map.toSource(1, before)); assertEquals(9, map.toSource(1, after))
        assertEquals(2, map.clippedRanges.size)
        assertEquals("XXsame", map.visual)
        for (visualOffset in 0..map.visual.length) {
            assertEquals(visualOffset, map.toVisual(map.toSource(visualOffset, before)))
            assertEquals(visualOffset, map.toVisual(map.toSource(visualOffset, after)))
        }
        // Mapping retains every original UTF16 offset. Native shaping must still
        // decide whether a source boundary inside a combining sequence is a stop.
        val combining = NativeClippedSourceMap("a\u0301Xb", listOf(NativeClippedSourceRange(2, 3)))
        assertEquals("a\u0301b", combining.visual)
        assertEquals(1, combining.toVisual(1)); assertEquals(1, combining.toSource(1, before))
        val unchanged = NativeClippedSourceMap(original, emptyList())
        assertEquals(original, unchanged.visual)
        assertEquals(listOf(NativeClippedVisibleRange(0, original.length, 0, original.length)),
            unchanged.visibleIntersections(0, original.length))
        for (offset in 0..original.length) {
            assertEquals(offset, unchanged.toVisual(offset))
            assertEquals(offset, unchanged.toSource(offset, before))
            assertEquals(offset, unchanged.toSource(offset, after))
        }
    }

    @Test fun clippedPublicationSeparatesPlacementSnapshotsFromLiveSourceOwnership() {
        val sourceOwner = Any()
        var attached = true
        var sourceCurrent = true
        val owner = NativeClippedPublication(sourceOwner) { attached && sourceCurrent }
        val beforeReveal = NativeClippedPublicationSnapshot(owner)
        assertTrue(beforeReveal.isCurrent)
        assertSame(sourceOwner, owner.binding)

        // The root's own reveal moves the same source. Its old screen matrix
        // expires, but its callback may finish and request a fresh projection.
        owner.update { attached && sourceCurrent }
        assertTrue(!beforeReveal.isCurrent)
        assertTrue(beforeReveal.ownerIsCurrent)
        val placed = NativeClippedPublicationSnapshot(owner)
        assertTrue(placed.isCurrent)
        attached = false
        assertTrue(!placed.isCurrent)
        assertTrue(!placed.ownerIsCurrent)
        attached = true
        owner.update { attached && sourceCurrent }
        assertTrue(!placed.isCurrent)
        val recovered = NativeClippedPublicationSnapshot(owner)
        assertTrue(recovered.isCurrent)
        sourceCurrent = false
        assertTrue(!recovered.isCurrent)
        assertTrue(!recovered.ownerIsCurrent)

        // Source replacement cannot revive a captured callback, even when its
        // replacement is already attached at the same physical location.
        owner.retire()
        sourceCurrent = true
        val replacement = NativeClippedPublication(Any()) { attached && sourceCurrent }
        val replacementMap = NativeClippedPublicationSnapshot(replacement)
        assertTrue(replacementMap.isCurrent)
        assertTrue(!recovered.ownerIsCurrent)
        assertTrue(replacement.binding !== sourceOwner)
        replacement.retire()
        assertTrue(!replacementMap.isCurrent)
        assertTrue(!replacementMap.ownerIsCurrent)
    }

    @Test fun clippedScrollEscapeKeepsRootViewportMotionAndDeduplicatesActualViewportIdentity() {
        class Viewport(val label: String, var parent: Viewport? = null) {
            override fun equals(other: Any?) = other is Viewport && other.label == label
            override fun hashCode() = label.hashCode()
        }
        val document = Viewport("document")
        val table = Viewport("scroll", document)
        val inner = Viewport("scroll", table)
        assertEquals(table, inner) // Equal values still represent distinct owners.
        fun escaped(boundary: Viewport?, virtual: List<Viewport>) =
            nativeClippedScrollEscapes(inner, boundary, virtual) { it.parent }

        // The source View and aggregate table geometry expose the same table.
        // Its pan is undone once; document scrolling remains authoritative.
        val outsideTable = escaped(document, listOf(table, table))
        assertEquals(2, outsideTable.size)
        assertSame(table, outsideTable[0].owner)
        assertEquals(0, outsideTable[0].virtualIndex)
        assertSame(inner, outsideTable[1].owner)
        assertNull(outsideTable[1].virtualIndex)
        val translations = java.util.IdentityHashMap<Viewport, Float>().apply {
            put(document, -31f); put(table, -19f); put(inner, -7f)
        }
        val actualSourceX = 100f + translations.getValue(document) + translations.getValue(table) + translations.getValue(inner)
        assertEquals(69f, actualSourceX - outsideTable.sumOf { translations.getValue(it.owner).toDouble() }.toFloat(), 0f)

        // Only descendants of the published root viewport boundary are undone.
        // Moving that actual boundary inward retains its own outer motion.
        val insideTable = escaped(table, listOf(table))
        assertEquals(1, insideTable.size)
        assertSame(inner, insideTable.single().owner)
        assertEquals(50f, actualSourceX - translations.getValue(insideTable.single().owner), 0f)
        assertTrue(escaped(inner, listOf(table, inner)).isEmpty())
        assertEquals(43f, actualSourceX, 0f)
        val otherDocument = Viewport("document")
        invalid { escaped(otherDocument, emptyList()) }
        invalid { escaped(document, listOf(Viewport("scroll", otherDocument))) }
        val sibling = Viewport("scroll", document)
        invalid { escaped(document, listOf(sibling)) }
        invalid { nativeClippedScrollEscapes(document, document, listOf(table, sibling)) { it.parent } }
        val cycle = Viewport("cycle")
        cycle.parent = cycle
        invalid { nativeClippedScrollEscapes(cycle, document, emptyList()) { it.parent } }
        invalid { escaped(document, listOf(cycle)) }
    }

    @Test fun clippedProbeWorkAccountsBeforeShapingWithoutInventingATextBudget() {
        val work = NativeClippedProbeWork()
        work.charge(17L)
        work.charge(0L)
        work.charge(Long.MAX_VALUE - 17L)
        assertEquals(Long.MAX_VALUE, work.used)
        try { work.charge(1L); fail("Expected checked accounting overflow") }
        catch (_: UnsupportedFloatLayout) { }
        assertEquals(Long.MAX_VALUE, work.used)
        val recovery = NativeClippedProbeWork()
        try { recovery.charge(-1L); fail("Expected negative work refusal") }
        catch (_: UnsupportedFloatLayout) { }
        assertEquals(0L, recovery.used)
        recovery.charge((1L shl 20) + 1L)
        assertEquals((1L shl 20) + 1L, recovery.used)
    }
}
