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

    @Test fun ordinaryContainingBlocksKeepNestedPositionedOwnersInGlobalSourceOrder() {
        fun absolute(id: Int, text: Int, owner: Int) = NativePaintOrderNode(id, positioned = true,
            children = listOf(NativePaintOrderNode(text)), absolutePositionContainingBlock = owner)
        val source = listOf(
            NativePaintOrderNode(0, children = listOf(NativePaintOrderNode(1))),
            NativePaintOrderNode(2, positioned = true, absoluteContainingBlock = true, children = listOf(
                NativePaintOrderNode(3),
                NativePaintOrderNode(4, children = listOf(
                    absolute(5, 6, 2), NativePaintOrderNode(7),
                    NativePaintOrderNode(8, positioned = true, absoluteContainingBlock = true, children = listOf(
                        NativePaintOrderNode(9), NativePaintOrderNode(10, children = listOf(absolute(11, 12, 8))),
                        NativePaintOrderNode(13, positioned = true, children = listOf(NativePaintOrderNode(14))))),
                    NativePaintOrderNode(15))),
                absolute(16, 17, 2))),
            NativePaintOrderNode(18),
            NativePaintOrderNode(19, positioned = true, absoluteContainingBlock = true,
                children = listOf(NativePaintOrderNode(20), absolute(21, 22, 19))),
            NativePaintOrderNode(23))
        fun preorder(nodes: List<NativePaintOrderNode>): List<Int> = nodes.flatMap { listOf(it.source) + preorder(it.children) }
        val logical = (0..23).toList()
        assertEquals(logical, preorder(source))
        assertEquals(listOf(0, 1, 18, 23, 2, 3, 4, 7, 15, 5, 6, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 20, 21, 22),
            nativeContextPaintSequence(source))
        assertEquals(logical, preorder(source))
        assertEquals(logical.toSet(), nativeContextPaintSequence(source).toSet())
    }

    @Test fun ordinaryAbsolutePaintRequiresNearestSourceAuthorityAndRetainsScopeRefusals() {
        fun absolute(id: Int, owner: Int, children: List<NativePaintOrderNode> = emptyList()) =
            NativePaintOrderNode(id, positioned = true, children = children, absolutePositionContainingBlock = owner)
        fun containing(id: Int, children: List<NativePaintOrderNode>) = NativePaintOrderNode(id,
            positioned = true, children = children, absoluteContainingBlock = true)
        val roots = listOf(containing(0, listOf(NativePaintOrderNode(1, children = listOf(
            NativePaintOrderNode(2, children = listOf(absolute(3, 0, listOf(NativePaintOrderNode(4))))))))),
            NativePaintOrderNode(5))
        assertEquals(listOf(5, 0, 1, 2, 3, 4), nativeContextPaintSequence(roots))
        // Media keeps its source-preorder phase but does not become a containing block.
        assertEquals(listOf(5, 0, 1, 2, 3, 4, 8), nativeContextMediaPaintSequence(roots, mapOf(2 to 8)))
        assertThrows(IllegalArgumentException::class.java) {
            nativeContextPaintSequence(listOf(absolute(1, 0)))
        }
        assertThrows(IllegalArgumentException::class.java) {
            nativeContextPaintSequence(listOf(containing(0, listOf(absolute(1, 9)))))
        }
        assertThrows(IllegalArgumentException::class.java) {
            nativeContextPaintSequence(listOf(containing(0, listOf(containing(1, listOf(absolute(2, 0)))))))
        }
        assertThrows(IllegalArgumentException::class.java) {
            nativeContextPaintSequence(listOf(containing(0, listOf(NativePaintOrderNode(1, positioned = true,
                children = listOf(absolute(2, 0)))))))
        }
        assertThrows(IllegalArgumentException::class.java) {
            nativeContextPaintSequence(listOf(containing(0, listOf(absolute(1, 0, listOf(
                containing(2, listOf(absolute(3, 2)))))))))
        }
        assertThrows(IllegalArgumentException::class.java) {
            nativeContextPaintSequence(listOf(NativePaintOrderNode(0, absoluteContainingBlock = true)))
        }
        assertThrows(IllegalArgumentException::class.java) {
            nativeContextPaintSequence(listOf(containing(0, listOf(absolute(1, 0).copy(positioned = false)))))
        }
        assertThrows(IllegalArgumentException::class.java) {
            nativeContextPaintSequence(listOf(containing(0, listOf(label(1, 2)))), absoluteScope = true)
        }
        assertThrows(IllegalArgumentException::class.java) {
            nativeContextPaintSequence(listOf(absolute(1, 0).copy(absolute = true)), absoluteScope = true)
        }
        assertThrows(IllegalStateException::class.java) {
            nativeContextPaintSequence(listOf(containing(0, listOf(absolute(1, 0), NativePaintOrderNode(1)))))
        }
        // Legacy direct-scope roots remain independently authenticated in a mixed new-mode tree.
        val mixed = listOf(containing(0, listOf(NativePaintOrderNode(1))), label(2, 3))
        assertEquals(listOf(0, 1, 2, 3), nativeContextPaintSequence(mixed, absoluteScope = true))
        assertThrows(IllegalArgumentException::class.java) { nativeContextPaintSequence(mixed) }
    }
}
