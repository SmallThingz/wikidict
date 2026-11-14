package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Pure source-map controls. Native shaping, ink and source-action behavior require device controls. */
class NativeNoWrapTest {
    private fun owner(source: CharSequence) = NativeInlineRange(0, source.length,
        NativeAuthoredTextWrap(TextWrap.NoWrap, inheritedOwner = true))
    private fun plan(source: CharSequence) = checkNotNull(NativeNoWrapPlan.create(source, listOf(owner(source))))
    private fun refuses(body: () -> Unit) {
        try { body(); fail("Expected explicit native no-wrap refusal") }
        catch (_: UnsupportedFloatLayout) { }
    }

    @Test fun hardLinesKeepUtf16OffsetsTrailingSpacesAndEveryEmptyLine() {
        val source = " A \uD83D\uDE00 \n\nB\n"
        val value = plan(source)
        assertEquals(10, source.length)
        assertEquals(listOf(NativeNoWrapParagraph(0, 6, 7), NativeNoWrapParagraph(7, 7, 8),
            NativeNoWrapParagraph(8, 9, 10), NativeNoWrapParagraph(10, 10, 10)), value.paragraphs)
        val measured = mutableListOf<Triple<Int, Int, String>>()
        val maximum = value.maximumAdvance { start, end ->
            measured += Triple(start, end, source.substring(start, end))
            if (start == 0) 52.25f else 7f
        }
        assertEquals(52.25f, maximum, 0f)
        assertEquals(listOf(Triple(0, 6, " A \uD83D\uDE00 "), Triple(8, 9, "B")), measured)
        assertEquals(" A \uD83D\uDE00 \n\nB\n", source)
        value.validateLines(intArrayOf(0, 7, 8, 10), intArrayOf(7, 8, 10, 10))
    }

    @Test fun finalNativeLinesCannotBreakAtSpacesOrEmergencyPositions() {
        val source = "alpha beta\nlongword"
        val value = plan(source)
        value.validateLines(intArrayOf(0, 11), intArrayOf(11, 19))
        // A legal ordinary space opportunity is still forbidden for this complete owner.
        refuses { value.validateLines(intArrayOf(0, 6, 11), intArrayOf(6, 11, 19)) }
        refuses { value.validateLines(intArrayOf(0, 11, 15), intArrayOf(11, 15, 19)) }
        // Joining across the explicit LF is equally invalid.
        refuses { value.validateLines(intArrayOf(0), intArrayOf(19)) }
        refuses { value.validateLines(intArrayOf(0, 11), intArrayOf(10, 19)) }
        assertEquals(value.paragraphs[0], value.paragraphAt(0))
        assertEquals(value.paragraphs[0], value.paragraphAt(6))
        assertEquals(value.paragraphs[1], value.paragraphAt(11))
        assertEquals(value.paragraphs[1], value.paragraphAt(15))
        refuses { value.paragraphAt(-1) }
        refuses { value.paragraphAt(20) }
    }

    @Test fun wholeOwnerGateRefusesChildOverridesWithoutChangingExistingPolicies() {
        val source = "one two"
        val full = owner(source)
        assertNotNull(NativeNoWrapPlan.create(source, listOf(full)))
        for (child in listOf(TextWrap.Normal, TextWrap.BreakWord)) {
            val explicit = NativeInlineRange(4, 7, NativeAuthoredTextWrap(child))
            assertNull(NativeNoWrapPlan.create(source, listOf(explicit)))
            refuses { NativeNoWrapPlan.create(source, listOf(full, explicit)) }
            assertNull(NativeNoWrapPlan.create(source, listOf(NativeInlineRange(0, source.length,
                NativeAuthoredTextWrap(child, inheritedOwner = true)))))
        }
        assertNull(NativeNoWrapPlan.create(source, emptyList()))
        refuses { NativeNoWrapPlan.create(source, listOf(full.copy(end = 3))) }
        refuses { NativeNoWrapPlan.create(source, listOf(full.copy(start = 1))) }
        refuses { NativeNoWrapPlan.create(source, listOf(full.copy(value = NativeAuthoredTextWrap(TextWrap.NoWrap)))) }
        refuses { NativeNoWrapPlan.create(source, listOf(full, full.copy())) }
    }

    @Test fun noWrapRefusesUnprovedTabAndHardBreakMappingsButRetainsBidiAndNbsp() {
        for (control in listOf('\t', '\r', '\u000b', '\u000c', '\u0085', '\u2028', '\u2029'))
            refuses { plan("A${control}B") }
        val source = "\u2067\u05d0 \u05d1\u2069\u00a0Z"
        val value = plan(source)
        assertEquals(listOf(NativeNoWrapParagraph(0, source.length, source.length)), value.paragraphs)
        val calls = mutableListOf<String>()
        assertEquals(33.5f, value.maximumAdvance { start, end ->
            calls += source.substring(start, end); 33.5f
        }, 0f)
        assertEquals(listOf(source), calls)
        value.validateLines(intArrayOf(0), intArrayOf(source.length))
    }

    @Test fun emptySourceAndTrailingHardLineKeepTheirBoundariesWithoutMeasuringInventedText() {
        val empty = plan("")
        assertEquals(listOf(NativeNoWrapParagraph(0, 0, 0)), empty.paragraphs)
        assertEquals(0f, empty.maximumAdvance { _, _ -> fail("Empty source must not add a measurement space"); 0f }, 0f)
        empty.validateLines(intArrayOf(0), intArrayOf(0))
        refuses { empty.validateLines(intArrayOf(), intArrayOf()) }
        val hard = plan("\n")
        assertEquals(0f, hard.maximumAdvance { _, _ -> fail("Hard breaks must not add measurement glyphs"); 0f }, 0f)
        hard.validateLines(intArrayOf(0, 1), intArrayOf(1, 1))
        refuses { hard.validateLines(intArrayOf(0), intArrayOf(1)) }
    }

    @Test fun invalidNativeAdvancesRefuseBeforeFitOrIntrinsicIntegerConversion() {
        val value = plan("source")
        for (advance in listOf(-.25f, Float.NaN, Float.POSITIVE_INFINITY, TablePixelLimit + 1f))
            refuses { value.maximumAdvance { _, _ -> advance } }
        refuses { value.maximumAdvance { _, _ -> throw IllegalArgumentException("cross-paragraph measurement") } }
        assertEquals(TablePixelLimit.toFloat(), value.maximumAdvance { _, _ -> TablePixelLimit.toFloat() }, 0f)
        assertEquals(.25f, value.maximumAdvance { _, _ -> .25f }, 0f)
    }

    @Test fun imageRangeAdmissionKeepsExistingObjectOffsetsAndHardLines() {
        val source = "left\ufffc middle\ufffcright\n"
        val ranges = listOf(12 to 13, 4 to 5)
        validateNativeNoWrapImageRanges(source, ranges)
        assertEquals(listOf(12 to 13, 4 to 5), ranges)
        assertEquals(2, source.count { it == '\ufffc' })
        assertEquals("left\ufffc middle\ufffcright\n", source)
        val value = plan(source)
        assertEquals(listOf(NativeNoWrapParagraph(0, 18, 19), NativeNoWrapParagraph(19, 19, 19)), value.paragraphs)
        value.validateLines(intArrayOf(0, 19), intArrayOf(19, 19))
        validateNativeNoWrapImageRanges("", emptyList())
    }

    @Test fun imageRangeAdmissionRejectsOverlapsAndNonObjectOrExpandedRanges() {
        val source = "A\ufffcB\ufffc"
        for (ranges in listOf(listOf(-1 to 0), listOf(4 to 5), listOf(0 to 1), listOf(2 to 3),
                listOf(1 to 1), listOf(1 to 3), listOf(1 to 4), listOf(1 to 2, 1 to 2)))
            refuses { validateNativeNoWrapImageRanges(source, ranges) }
        validateNativeNoWrapImageRanges(source, listOf(1 to 2, 3 to 4))
        assertEquals("A\ufffcB\ufffc", source)
    }

    private fun presentPlan(source: String, starts: List<Int>) = checkNotNull(NativeNoWrapPlan.create(source,
        listOf(owner(source).copy(value = NativeAuthoredTextWrap(TextWrap.NoWrap, true, starts)))))

    @Test fun sourceLinePresenceKeepsHardBreakLinesButNeverCreatesAnEofLine() {
        val textBreak = presentPlan("X\n", listOf(0))
        assertTrue(textBreak.hasLineAt(0)); assertFalse(textBreak.hasLineAt(2))
        textBreak.validateLines(intArrayOf(0, 2), intArrayOf(2, 2)) // Native offset slots remain intact.
        val oneBreak = presentPlan("\n", listOf(0))
        assertTrue(oneBreak.hasLineAt(0)); assertFalse(oneBreak.hasLineAt(1))
        val twoBreaks = presentPlan("\n\n", listOf(0, 1))
        assertTrue(twoBreaks.hasLineAt(0)); assertTrue(twoBreaks.hasLineAt(1)); assertFalse(twoBreaks.hasLineAt(2))
        assertEquals(0f, twoBreaks.maximumAdvance { _, _ -> fail("Breaks have no measurement glyph"); 0f }, 0f)
    }

    @Test fun absentCompiledContentHasZeroIntrinsicAdvanceEvenWhenReaderIsolatesRemain() {
        for (source in listOf("", "\u2067\u2069")) {
            val value = presentPlan(source, emptyList())
            value.requireLinePresence()
            assertFalse(value.hasLineAt(0))
            assertEquals(0f, value.maximumAdvance { _, _ -> fail("Absent source content cannot acquire a font width"); 0f }, 0f)
        }
        refuses { plan("X").requireLinePresence() }
        val calls = mutableListOf<Pair<Int, Int>>()
        assertEquals(12f, presentPlan("X\n", listOf(0)).maximumAdvance { start, end ->
            calls += start to end; 12f
        }, 0f)
        assertEquals(listOf(0 to 1), calls)
    }

    @Test fun linePresenceCannotClaimTerminalEofOrContradictHardBreakOffsets() {
        refuses { presentPlan("", listOf(0)) }
        refuses { presentPlan("X\n", listOf(0, 2)) }
        refuses { presentPlan("X\n", emptyList()) }
        refuses { presentPlan("\n\n", listOf(0)) }
        refuses { presentPlan("X\nY", listOf(0, 0, 2)) }
        refuses { presentPlan("X\nY", listOf(2, 0)) }
        refuses { presentPlan("X\nY", listOf(0, 1)) }
        val starts = mutableListOf(0)
        val value = presentPlan("X", starts)
        starts.clear()
        assertTrue(value.hasLineAt(0)) // A geometry plan snapshots the lowering's authority.
    }
}
