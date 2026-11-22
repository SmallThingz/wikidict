package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativeInlineBoxBottomTest {
    @Test fun alignedSubtreesDoNotInflateTheBaselineEnvelope() {
        val ordinary = NativeUsedLineMetrics(-8f, 4f)
        val bottom = NativeUsedLineMetrics(-14f, 2f)
        val result = nativeInlineBottomLineMetrics(ordinary, listOf(bottom))
        assertEquals(NativeUsedLineMetrics(-8f, 8f), result)
        assertEquals(16f, result.height, 0f)
        assertEquals(18f, ordinary.including(bottom).height, 0f)
        val shift = result.bottom - bottom.bottom
        assertEquals(result.top, bottom.top + shift, 0f)
        assertEquals(result.bottom, bottom.bottom + shift, 0f)
    }

    @Test fun tallerBaselineSiblingAndMultipleBottomOwnersConstrainHeightOnce() {
        val root = NativeUsedLineMetrics(-8f, 2f)
        val sibling = NativeUsedLineMetrics(-18f, 7f)
        val small = NativeUsedLineMetrics(-5f, 1f)
        val tall = NativeUsedLineMetrics(-26f, 4f)
        val line = nativeInlineBottomLineMetrics(root.including(sibling), listOf(small, tall))
        assertEquals(NativeUsedLineMetrics(-18f, 12f), line)
        assertEquals(30f, line.height, 0f)
        for (owner in listOf(small, tall)) {
            val shift = line.bottom - owner.bottom
            assertEquals(line.bottom, owner.bottom + shift, 0f)
            assertTrue(owner.top + shift >= line.top)
        }
        assertEquals(sibling, nativeInlineBottomLineMetrics(root.including(sibling), listOf(small)))
        assertEquals(root, nativeInlineBottomLineMetrics(root, emptyList()))
    }

    @Test fun wrappedFragmentsKeepSeparateBottomAndBoundaryAffinity() {
        val metrics = NativeUsedLineMetrics(-8f, 6f)
        val first = NativeInlineBottomLine(metrics,
            listOf(NativeInlineBottomFragment(2, 8, NativeUsedLineMetrics(-10f, 2f), 4f)))
        val second = NativeInlineBottomLine(NativeUsedLineMetrics(-8f, 2f),
            listOf(NativeInlineBottomFragment(8, 12, NativeUsedLineMetrics(-5f, 1f), 1f)))
        assertNull(first.at(2, upstream = true))
        assertEquals(4f, first.at(2)!!.shift, 0f)
        assertNull(first.at(8))
        assertEquals(4f, first.at(8, upstream = true)!!.shift, 0f)
        assertEquals(1f, second.at(8)!!.shift, 0f)
        assertNull(second.at(12))
        assertEquals(1f, second.at(12, upstream = true)!!.shift, 0f)
    }
}
