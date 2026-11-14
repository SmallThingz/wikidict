package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Ordinary source link state controls. Private source only; no execution claimed. */
class OrdinaryLinkPaintTest {
    private fun policy(focusUnderline: Boolean = true) = LinkPaint(
        normal = FigureLinkState("#102030", false), hover = FigureLinkState("#203040", true),
        active = FigureLinkState("#304050", false), hoverActive = FigureLinkState("#708090", true),
        visited = FigureLinkState("#405060", true), visitedHover = FigureLinkState("#506070", false),
        visitedActive = FigureLinkState("#607080", false), visitedHoverActive = FigureLinkState("#8090a0", true),
        underlineOnFocus = focusUnderline)

    private fun painted(text: String = "One", target: String = "Target", kind: String = "link",
        trail: String = "", direction: String = "", paint: LinkPaint = policy()) =
        Span(kind, text, target, trail = trail, direction = direction, foreground = paint.normal.foreground,
            underline = paint.normal.underline, linkPaint = paint)

    @Test fun allEightStatesKeepHoverActiveDistinctAndFocusDoesNotReplaceTheSelectedColor() {
        val cases = listOf(
            Triple(false, false, false) to (0x102030 to false),
            Triple(false, true, false) to (0x203040 to true),
            Triple(false, false, true) to (0x304050 to false),
            Triple(false, true, true) to (0x708090 to true),
            Triple(true, false, false) to (0x405060 to true),
            Triple(true, true, false) to (0x506070 to false),
            Triple(true, false, true) to (0x607080 to false),
            Triple(true, true, true) to (0x8090a0 to true),
        )
        for ((flags, expected) in cases) for (focus in listOf(false, true)) {
            val state = NativeMissingLinkPaint(policy(), flags.first).apply {
                hovered = flags.second; active = flags.third; focused = focus
            }
            assertEquals(0xff000000.toInt() or expected.first, state.appearance().color)
            assertEquals(expected.second || focus, state.appearance().underline)
        }
        // The static normal underline is a consistency field, not an independent child decoration.
        val removingUnderline = policy(false).copy(normal = FigureLinkState("#102030", true))
        for (visited in listOf(false, true)) {
            val state = NativeMissingLinkPaint(removingUnderline, visited)
            assertTrue(state.appearance().underline)
            state.active = true; state.focused = true
            assertEquals(if (visited) 0xff607080.toInt() else 0xff304050.toInt(), state.appearance().color)
            assertFalse(state.appearance().underline)
            state.hovered = true
            assertEquals(if (visited) 0xff8090a0.toInt() else 0xff708090.toInt(), state.appearance().color)
            assertTrue(state.appearance().underline)
            state.hovered = false
            assertFalse(state.appearance().underline)
        }
    }

    @Test fun equalTargetsShareKnownVisitsButNeverShareHoverPressOrHeldOccurrenceIdentity() {
        val source = painted()
        val visits = MissingLinkVisits()
        val documentOwner = Any(); val paragraphOwner = Any()
        val target = missingLinkTarget(source, "de", "Mai")
        fun identity(index: Int, start: Int, span: Span = source, owner: Any = documentOwner) =
            MissingLinkActionIdentity(owner, target,
                NativeLinkOccurrenceIdentity(paragraphOwner, index, start, start + span.text.length, span))
        val firstIdentity = identity(0, 0)
        val secondIdentity = identity(1, 3)
        val first = NativeMissingLinkPaint(policy(), visits.contains(target), actionIdentity = firstIdentity)
        val second = NativeMissingLinkPaint(policy(), visits.contains(target), actionIdentity = secondIdentity)
        first.hovered = true; first.active = true; first.focused = true
        assertEquals(0xff708090.toInt(), first.appearance().color)
        assertEquals(0xff102030.toInt(), second.appearance().color)
        assertFalse(second.hovered); assertFalse(second.active); assertFalse(second.focused)
        visits.record(target)
        val visitedFirst = NativeMissingLinkPaint(policy(), visits.contains(target), actionIdentity = firstIdentity)
        val visitedSecond = NativeMissingLinkPaint(policy(), visits.contains(missingLinkTarget(source.copy(text = "Two"), "de", "Mai")),
            actionIdentity = secondIdentity)
        assertEquals(0xff405060.toInt(), visitedFirst.appearance().color)
        assertEquals(visitedFirst.appearance(), visitedSecond.appearance())
        var calls = 0
        val originalAction = { calls++; Unit }
        fun node(id: MissingLinkActionIdentity, action: () -> Unit = originalAction) =
            FloatInteractionNode(0, FloatInteractionKind.LINK, 0, 3, emptyList(), "One", null, action,
                missingLinkPaint = NativeMissingLinkPaint(policy(), true, actionIdentity = id))
        val held = NativeLinkKeyPress(0, 66, firstIdentity, originalAction)
        assertTrue(held.matches(node(firstIdentity, { calls++; Unit }))) // Same owner survives rebuilt callbacks.
        assertFalse(held.matches(node(secondIdentity)))
        assertFalse(held.matches(node(identity(0, 0, owner = Any()))))
        assertFalse(held.matches(node(identity(0, 0, span = source.copy(text = "Two")))))
        assertFalse(held.matches(node(firstIdentity).copy(id = 1)))
        assertEquals(0, calls) // Looking up a state or checking custody never activates a link.
    }

    @Test fun sessionHistorySeparatesInternalEditionsDocumentsAndFragmentsWithoutRemoteInference() {
        val visits = MissingLinkVisits()
        val internal = painted(target = "Target#part")
        val key = missingLinkTarget(internal, "de", "Mai")
        assertFalse(visits.contains(key))
        visits.record(key)
        assertTrue(visits.contains(missingLinkTarget(internal.copy(text = "Other label", target = "Target",
            targetFragment = "part"), "de", "Elsewhere")))
        assertFalse(visits.contains(missingLinkTarget(internal, "fr", "Mai")))
        assertFalse(visits.contains(missingLinkTarget(internal.copy(target = "Target", targetFragment = null), "de", "Mai")))
        assertFalse(visits.contains(missingLinkTarget(internal.copy(target = "Target", targetFragment = ""), "de", "Mai")))
        val local = painted(target = "#part")
        visits.record(missingLinkTarget(local, "de", "Mai"))
        assertFalse(visits.contains(missingLinkTarget(local, "de", "Juni")))
        val external = painted(target = "https://example.invalid/a#part", kind = "external_link")
        val externalKey = missingLinkTarget(external, "de", "Mai")
        visits.record(externalKey)
        assertTrue(visits.contains(missingLinkTarget(external, "fr", "Juni")))
        assertFalse(visits.contains(missingLinkTarget(external.copy(target = "//example.invalid/a#part"), "de")))
        assertFalse(visits.contains(missingLinkTarget(external.copy(target = "https://example.invalid/b#part"), "de")))
        assertFalse(MissingLinkVisits().contains(key))
        visits.clear()
        assertFalse(visits.contains(key)); assertFalse(visits.contains(externalKey))
    }

    @Test fun utf16BidiAndTrailRangesKeepTheirPolicyAcrossCopiesAndCompaction() {
        val first = painted("A\uD83D\uDE00", trail = "!", direction = "rtl")
        val external = painted("B", "https://example.invalid", "external_link", trail = "?", direction = "auto")
        val source = listOf(first, Span("line_break", ""), external, painted("C"))
        val ranges = nativeCaptionLinkRanges(source)
        assertEquals(listOf(0, 2, 3), ranges.map { it.index })
        assertEquals(listOf(0 to 6, 7 to 11, 11 to 12), ranges.map { it.start to it.end })
        assertSame(first, ranges.first().span)
        assertSame(first.linkPaint, first.copy(bold = true, tooltip = "advice").linkPaint)
        assertSame(source, compactSpans(source))
        val blank = painted(" ")
        val zero = painted("")
        val retained = compactSpans(listOf(blank, first, zero))
        assertEquals(listOf(blank, first, zero), retained)
        assertSame(blank, retained.first()); assertSame(zero, retained.last())
        assertEquals(NativeOrdinaryLinkPaintUnavailable, ordinaryLinkPaintUnavailable(retained))

        val repeated = painted("A  B")
        val crossLink = painted("\t A  B", trail = "\t\t")
        val collapsed = painted(" \t", direction = "rtl")
        val raw = listOf(Span("text", "prefix  "), crossLink, collapsed, Span("text", "\t tail"))
        for (kind in listOf("paragraph", "definition")) {
            val single = ordinaryInlineDisplaySpans(Block(kind, 0, listOf(repeated)))
            assertEquals(listOf(repeated.copy(text = "A B")), single)
            assertSame(repeated.linkPaint, single.single().linkPaint)
            assertNull(ordinaryLinkPaintUnavailable(single))
            val displayed = ordinaryInlineDisplaySpans(Block(kind, 0, raw))
            val legacy = ordinaryInlineDisplaySpans(Block(kind, 0, raw.map { it.copy(linkPaint = null) }))
            assertEquals("prefix A B tail", displayed.joinToString("") { it.text + it.trail })
            assertEquals(legacy.joinToString("") { it.text + it.trail },
                displayed.joinToString("") { it.text + it.trail })
            assertEquals(crossLink.copy(text = "A B", trail = " "), displayed[1])
            assertSame(crossLink.linkPaint, displayed[1].linkPaint)
            // Keep the now-empty authored action for explicit refusal, never as an invisible link.
            assertEquals(collapsed.copy(text = ""), displayed[2])
            assertEquals(NativeOrdinaryLinkPaintUnavailable, ordinaryLinkPaintUnavailable(displayed))
        }
        assertEquals("A  B", repeated.text)
        assertEquals("\t A  B", crossLink.text); assertEquals("\t\t", crossLink.trail)
        assertEquals(" \t", collapsed.text)
    }

    @Test fun nativeAdmissionRefusesEveryUnrepresentedPaintedActionWithoutChangingLegacyNulls() {
        val valid = listOf(painted(), painted("Outside", "https://example.invalid", "external_link"),
            painted("", trail = "visible trail"))
        assertNull(ordinaryLinkPaintUnavailable(valid))
        val invalidExternal = painted("Unsafe", "javascript:alert(1)", "external_link")
        val emptyRuns = listOf("", "rtl", "ltr", "auto").map { painted("", direction = it) }
        for (bad in listOf(invalidExternal) + emptyRuns) {
            assertEquals(NativeOrdinaryLinkPaintUnavailable, ordinaryLinkPaintUnavailable(listOf(bad)))
            assertEquals(NativeOrdinaryLinkPaintUnavailable, ordinaryLinkPaintUnavailable(valid + bad))
            assertNull(ordinaryLinkPaintUnavailable(listOf(bad.copy(linkPaint = null))))
        }
        assertNull(ordinaryLinkPaintUnavailable(emptyList()))
        assertNull(ordinaryLinkPaintUnavailable(listOf(Span("text", "ordinary body"))))
        assertNull(ordinaryLinkPaintUnavailable(listOf(painted(" "))))
    }
}
