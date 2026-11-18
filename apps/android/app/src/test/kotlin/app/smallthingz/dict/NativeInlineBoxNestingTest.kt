package app.smallthingz.dict

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NativeInlineBoxNestingTest {
    @Test fun strictInteriorPairKeepsOriginalPostorderAndDisjointOwners() {
        assertEquals(listOf(1, -1, -1), nativeInlineBoxNestedParents(listOf(2 to 3, 1 to 5, 6 to 8)))
        assertEquals(listOf(-1, 0), nativeInlineBoxNestedParents(listOf(1 to 5, 2 to 3)))
        assertEquals(listOf(-1, -1), nativeInlineBoxNestedParents(listOf(0 to 2, 2 to 5)))
    }
    @Test fun unselectedOverlapsEndpointsAndDeeperTreesRefuseWithoutChangingTheNextPair() {
        for (ranges in listOf(listOf(1 to 4, 3 to 5), listOf(1 to 5, 1 to 3),
                listOf(1 to 5, 2 to 5), listOf(1 to 5, 1 to 5), listOf(0 to 8, 1 to 7, 2 to 3),
                listOf(0 to 8, 1 to 3, 4 to 6), listOf(0 to 0))) assertNull(nativeInlineBoxNestedParents(ranges))
        assertEquals(listOf(-1, 0), nativeInlineBoxNestedParents(listOf(1 to 5, 2 to 3)))
    }
}
