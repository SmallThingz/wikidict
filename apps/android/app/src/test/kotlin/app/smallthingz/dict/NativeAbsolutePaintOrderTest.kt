package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativeAbsolutePaintOrderTest {
    private fun label(id: Int, text: Int) = NativePaintOrderNode(id, positioned = true,
        children = listOf(NativePaintOrderNode(text)), absolute = true)

    @Test fun directAbsoluteLabelsPaintAfterNormalBodyInTheirOriginalSiblingOrder() {
        val source = listOf(label(0, 1), NativePaintOrderNode(2), label(3, 4),
            label(5, 6), NativePaintOrderNode(7), label(8, 9))
        val logical = source.flatMap { listOf(it.source) + it.children.map { child -> child.source } }
        assertEquals(listOf(2, 7, 0, 1, 3, 4, 5, 6, 8, 9),
            nativeContextPaintSequence(source, absoluteScope = true))
        // The last real label gets the highest input rank without sorting source traversal.
        assertEquals(9, nativeContextPaintSequence(source, absoluteScope = true).last())
        assertEquals(listOf(0, 1, 2, 3, 4, 5, 6, 7, 8, 9), logical)
        assertEquals(logical, source.flatMap { listOf(it.source) + it.children.map { child -> child.source } })
    }

    @Test fun scopeAdmitsOnlyDirectAbsoluteRootsAndRetainsLegacyNestedRefusal() {
        val absolute = label(1, 2)
        assertThrows(IllegalArgumentException::class.java) { nativeContextPaintSequence(listOf(absolute)) }
        assertThrows(IllegalArgumentException::class.java) {
            nativeContextPaintSequence(listOf(NativePaintOrderNode(0, children = listOf(absolute))), true)
        }
        assertThrows(IllegalArgumentException::class.java) {
            nativeContextPaintSequence(listOf(absolute.copy(positioned = false)), true)
        }
        assertThrows(IllegalArgumentException::class.java) {
            nativeContextPaintSequence(listOf(absolute.copy(children = listOf(label(3, 4)))), true)
        }
        assertThrows(IllegalArgumentException::class.java) {
            nativeContextPaintSequence(listOf(NativePaintOrderNode(0, true,
                listOf(NativePaintOrderNode(1, true)))), true)
        }
        val ordinary = listOf(NativePaintOrderNode(0, children = listOf(NativePaintOrderNode(1, true,
            listOf(NativePaintOrderNode(2))), NativePaintOrderNode(3))), NativePaintOrderNode(4))
        assertEquals(listOf(0, 3, 4, 1, 2), nativeContextPaintSequence(ordinary))
    }

    @Test fun deferredOrdinaryMediaPrecedesAbsoluteLabelsWithoutLendingScopeToItsChildren() {
        val roots = listOf(NativePaintOrderNode(0), label(1, 2), NativePaintOrderNode(3))
        assertEquals(listOf(0, 3, 10, 1, 2),
            nativeContextMediaPaintSequence(roots, mapOf(0 to 10), absoluteScope = true))
        assertThrows(IllegalArgumentException::class.java) {
            nativeContextMediaPaintSequence(roots, mapOf(2 to 11), absoluteScope = true)
        }
        assertThrows(IllegalStateException::class.java) {
            nativeContextPaintSequence(listOf(label(1, 2), label(3, 2)), absoluteScope = true)
        }
    }
}
