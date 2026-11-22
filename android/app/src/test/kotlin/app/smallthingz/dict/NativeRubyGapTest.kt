package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Pure visual-policy controls; caller-owned Ruby classification, fonts and paint are not exercised. */
class NativeRubyGapTest {
    @Test fun controlsCollapseToSpaceWithTheOriginalSurvivingUtf16Owner() {
        val cases = listOf(" " to 0, "\t\t " to 0, "\r" to 0, " \r\t" to 0,
            "\n" to 0, "\r\n" to 1, " \t\r\n\t\n " to 3)
        for ((raw, offset) in cases) {
            val fullSource = "\ud83d\ude80" + raw + "e\u0301"
            val original = fullSource.toCharArray()
            val actual = nativeRubyGapCollapse(raw, structurallyDiscarded = false,
                previousCollapsibleSpace = false, followingCollapsibleSpace = false, trimAtLineEdge = false)
            assertEquals(NativeRubyGapCollapse(" ", offset, false, false), actual)
            assertEquals(raw[offset], fullSource[2 + checkNotNull(actual.sourceOffset)])
            assertEquals(raw, fullSource.substring(2, 2 + raw.length))
            assertArrayEquals(original, fullSource.toCharArray())
        }
        assertEquals(NativeRubyGapCollapse("", null, false, false),
            nativeRubyGapCollapse("", false, true, true, false))
        // The selected UA policy transforms LF to SPACE without guessing the neighboring script.
        assertEquals(" ", nativeRubyGapCollapse("\n\n", false, false, false, false).text)
    }

    @Test fun adjacencyKeepsTheFirstSpaceButLfReplacesItsSurroundingOwners() {
        assertEquals(NativeRubyGapCollapse("", null, false, true),
            nativeRubyGapCollapse("\t \r", false, true, true, false))
        assertEquals(NativeRubyGapCollapse(" ", 0, false, true),
            nativeRubyGapCollapse("\t \r", false, false, true, false))
        assertEquals(NativeRubyGapCollapse("", null, false, false),
            nativeRubyGapCollapse("\r", false, true, false, false))
        assertEquals(NativeRubyGapCollapse(" ", 1, true, true),
            nativeRubyGapCollapse("\r\n\t", false, true, true, false))
        assertEquals(NativeRubyGapCollapse(" ", 2, false, true),
            nativeRubyGapCollapse(" \t\n\n", false, false, true, false))
        assertEquals(NativeRubyGapCollapse(" ", 0, true, false),
            nativeRubyGapCollapse("\n", false, true, false, false))
        // A new level/segment context resets adjacency; no preceding owner is borrowed across it.
        val continuing = nativeRubyGapCollapse(" ", false, true, false, false)
        val reset = nativeRubyGapCollapse(" ", false, false, false, false)
        assertEquals("", continuing.text)
        assertEquals(NativeRubyGapCollapse(" ", 0, false, false), reset)
    }

    @Test fun structuralDiscardAndLineTrimHaveDifferentNeighborEffects() {
        val raw = " \r\n\t "
        assertEquals(NativeRubyGapCollapse("", null, false, false),
            nativeRubyGapCollapse(raw, true, true, true, false))
        assertEquals(NativeRubyGapCollapse("", null, false, false),
            nativeRubyGapCollapse(raw, true, true, true, true))
        val untrimmed = nativeRubyGapCollapse(raw, false, true, true, false)
        assertEquals(NativeRubyGapCollapse(" ", 2, true, true), untrimmed)
        assertEquals(NativeRubyGapCollapse("", null, true, true),
            nativeRubyGapCollapse(raw, false, true, true, true))
        assertEquals(NativeRubyGapCollapse("", null, false, true),
            nativeRubyGapCollapse("\t ", false, false, true, true))
        assertEquals(NativeRubyGapCollapse("", null, false, false),
            nativeRubyGapCollapse("", false, true, true, true))
        // Reflow restores the retained gap from raw source, not from the previously trimmed result.
        assertEquals(untrimmed, nativeRubyGapCollapse(raw, false, true, true, false))
        assertEquals(" \r\n\t ", raw)
    }

    @Test fun formFeedCannotDisappearThroughDiscardAndInvalidInputDoesNotPoisonRecovery() {
        val raw = "\t\u000c\n"
        for (discard in listOf(false, true)) for (trim in listOf(false, true)) {
            try {
                nativeRubyGapCollapse(raw, discard, true, true, trim)
                fail("Form feed requires explicit unsupported handling")
            } catch (failure: UnsupportedFloatLayout) {
                assertEquals("Ruby gap form feed is unavailable", failure.message)
            }
        }
        for (nonGap in listOf("A", "\u00a0", "\u2003", "\u000b", "\ud83d\ude80")) {
            try {
                nativeRubyGapCollapse(nonGap, true, false, false, true)
                fail("Non-gap text must not be silently discarded")
            } catch (failure: IllegalArgumentException) {
                assertFalse(failure is UnsupportedFloatLayout)
            }
        }
        assertEquals("\t\u000c\n", raw)
        assertEquals(NativeRubyGapCollapse(" ", 1, true, true),
            nativeRubyGapCollapse("\r\n", false, true, true, false))
        assertEquals(NativeRubyGapCollapse(" ", 0, false, false),
            nativeRubyGapCollapse("\t", false, false, false, false))
    }
}
