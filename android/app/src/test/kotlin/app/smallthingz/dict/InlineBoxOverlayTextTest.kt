package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class InlineBoxOverlayTextTest {
    private val zero = StyleLength(StyleLengthUnit.Px, 0f)
    private val none = InlineBoxBorderEdge.None
    private val borders = InlineBoxBorderEdges(none, none, none, none)
    private val font = InlineFontSnapshot(14f, FontScaleBasis.CssPx, fontNormalized = true)
    private fun leaf(text: String) = Span("text", text, fontScale = 14f, fontScaleBasis = FontScaleBasis.CssPx)
    private fun body(at: Long, text: String) = InlineBoxOverlay(InlineBoxInsets(
        top = InlineBoxInset(StyleWidthUnit.Px, 0f), right = InlineBoxInset(StyleWidthUnit.Percent, 0f)),
        borders, InlineBoxOverlayContent(at, font, null, InlineBoxOverlayTextAlign.Start, listOf(leaf(text))))

    @Test fun detachedSourceInterleavesOriginalBoundariesAndPreservesActionsAndUtf16Identity() {
        val original = listOf(Span("link", "A\ud83d\ude80", "Original", targetFragment = "section"), Span("text", "B"))
        val decorations = listOf(body(0, "["), body(1, "\u200b"),
            InlineBoxOverlay(InlineBoxInsets(top = InlineBoxInset(StyleWidthUnit.Px, 0f),
                right = InlineBoxInset(StyleWidthUnit.Px, 0f)), borders), body(1, "\ud83d\ude00"), body(2, "]"))
        val group = InlineBoxGroup(StyleEdges(zero, zero, zero, zero), borders, decorations, original)
        val owner = Span("text", "", inlineBoxGroup = group)
        val logical = "[A\ud83d\ude80\u200b\ud83d\ude00B]"
        val projection = rubyGraphicalProjection(listOf(owner), "original")
        assertEquals(logical, projection.text)
        assertEquals(listOf(0, 1, 3, 4), projection.ranges.filter { it.role == RubyTextRole.OverlayContent }.map { it.overlayIndex })
        assertEquals(listOf(0 to 1, 4 to 5, 5 to 7, 8 to 9),
            projection.ranges.filter { it.role == RubyTextRole.OverlayContent }.map { it.start to it.end })
        val action = projection.ranges.single { it.span === original[0] }
        assertEquals(1 to 4, action.start to action.end)
        assertTrue(action.path.endsWith("/spans/0"))
        assertSame(original[0], action.span)
        assertEquals(EntryLink("Original", "section"), action.span!!.entryLink())
        assertSame(original, group.spans)
        val repeated = rubyGraphicalProjection(listOf(owner, owner), "original")
        assertEquals(logical + logical, repeated.text)
        assertEquals(8, repeated.ranges.count { it.role == RubyTextRole.OverlayContent })
        assertEquals(8, repeated.ranges.filter { it.role == RubyTextRole.OverlayContent }.map { it.path }.distinct().size)
        assertEquals(2, repeated.ranges.count { it.span === original[0] })
    }

    @Test fun logicalAndVisualFallbackRetainDetachedTextWhileNullDecorationRetainsLegacyText() {
        val child = Span("link", "in flow", "Destination", tooltip = "original hint")
        val decoration = body(1, "\u200b")
        val group = InlineBoxGroup(StyleEdges(zero, zero, zero, zero), borders, listOf(decoration), listOf(child))
        val source = listOf(Span("text", "", inlineBoxGroup = group))
        for (fallback in listOf(rubyFallbackSpans(source), rubyVisualFallbackSpans(source))) {
            assertEquals("in flow\u200b", fallback.joinToString("") { it.text + it.trail })
            assertSame(child, fallback.first())
            assertSame(decoration.content!!.spans.single(), fallback.last())
        }
        assertEquals("in flow\u200b", rubyBaseText(source))
        val terminal = rubyNativeTerminalProjection(source)
        assertSame(source, terminal.source)
        assertEquals("in flow\u200b", terminal.projection.text)
        val legacy = listOf(source.single().copy(inlineBoxGroup = group.copy(overlays = listOf(decoration.copy(content = null)))))
        assertEquals("in flow", rubyGraphicalProjection(legacy).text)
        assertEquals("in flow", rubyBaseText(legacy))
        assertSame(child, rubyVisualFallbackSpans(legacy).single())
    }

    @Test fun oppositeInsetsUseTheRelativePaddingBoxAndDoNotInventTextHeight() {
        val border = NativeInlineBoxBorders(NativeInlineBoxBorder(1f, 0), NativeInlineBoxBorder(4f, 0),
            NativeInlineBoxBorder(2f, 0), NativeInlineBoxBorder(2f, 0))
        val overlay = NativeInlineBoxOverlay(NativeInlineBoxInsets(NativeInlineBoxInset(0f, false),
            NativeInlineBoxInset(25f, true), NativeInlineBoxInset(67f, true), NativeInlineBoxInset(10f, false)), border)
        for (rtl in listOf(false, true)) {
            val value = nativeInlineBoxOverlayPlacement(overlay, NativeFloatBounds(10f, 20f, 110f, 60f), rtl, 0f, 30f) {
                fail("Opposite vertical insets determine used height independently of the real line"); 0f
            }
            assertEquals(20f, value.border.left, 0f)
            assertEquals(85f, value.border.right, 0f)
            assertEquals(20f, value.border.top, 0f)
            assertEquals(33.2f, value.border.bottom, .0001f)
            assertEquals(22f, value.contentLeft, 0f)
            assertEquals(21f, value.contentTop, 0f)
            assertEquals(59f, value.contentWidth, 0f)
            assertEquals(10.2f, value.contentHeight, .0001f)
        }
        val conflicting = overlay.copy(insets = overlay.insets.copy(left = NativeInlineBoxInset(90f, false),
            right = NativeInlineBoxInset(20f, false)))
        val ltr = nativeInlineBoxOverlayPlacement(conflicting, NativeFloatBounds(10f, 20f, 110f, 60f), false, 0f, 30f) { 99f }
        val rtl = nativeInlineBoxOverlayPlacement(conflicting, NativeFloatBounds(10f, 20f, 110f, 60f), true, 0f, 30f) { 99f }
        assertEquals(0f, ltr.contentWidth, 0f); assertEquals(0f, rtl.contentWidth, 0f)
        assertEquals(100f, ltr.border.left, 0f); assertEquals(84f, rtl.border.left, 0f)
    }

    @Test fun autoInsetUsesRealMinContentAndPreferredWidthsAndBottomAnchorsTheRealLineHeight() {
        val no = NativeInlineBoxBorder(0f, 0)
        val overlay = NativeInlineBoxOverlay(NativeInlineBoxInsets(null, NativeInlineBoxInset(20f, false),
            NativeInlineBoxInset(5f, false), null), NativeInlineBoxBorders(no, no, no, no))
        for ((minimum, preferred, expected) in listOf(Triple(10f, 30f, 30f), Triple(10f, 120f, 80f), Triple(90f, 120f, 90f))) {
            val used = mutableListOf<Float>()
            val value = nativeInlineBoxOverlayPlacement(overlay, NativeFloatBounds(10f, 20f, 110f, 60f), false,
                minimum, preferred) { width -> used += width; 27.5f }
            assertEquals(listOf(expected), used)
            assertEquals(expected, value.contentWidth, 0f)
            assertEquals(90f - expected, value.contentLeft, 0f)
            assertEquals(27.5f, value.contentTop, 0f)
            assertEquals(55f, value.border.bottom, 0f)
        }
    }
    @Test fun wrappedLtrContainingBoxUsesMeasuredFirstLastPaddingEdgesAndClampsCrossedOrder() {
        // Shared Chromium witness, with fractional coordinates retained. Middle
        // fragments never enlarge this containing rectangle.
        val first = NativeFloatBounds(51.5859375f, 3f, 68.59375f, 23f)
        val last = NativeFloatBounds(0f, 26f, 17.0078125f, 46f)
        assertEquals(NativeFloatBounds(first.left, first.top, first.left, last.bottom),
            nativeInlineBoxOverlayLtrContainingPadding(first, last))
        val none = NativeInlineBoxBorder(0f, 0)
        val browserOverlay = NativeInlineBoxOverlay(NativeInlineBoxInsets(NativeInlineBoxInset(0f, false),
            NativeInlineBoxInset(0f, true), NativeInlineBoxInset(67f, true), null),
            NativeInlineBoxBorders(none, NativeInlineBoxBorder(1f, 0), none, none))
        val placed = nativeInlineBoxOverlayPlacement(browserOverlay,
            nativeInlineBoxOverlayLtrContainingPadding(first, last), false, 0f, 0f) { error("Definite vertical insets") }
        assertEquals(51.5859375f, placed.border.right, 0f)
        assertEquals(3f, placed.border.top, 0f)
        // Chromium quantizes the percentage to layout units; retain its measured
        // sub-0.006px residual instead of claiming identical platform rounding.
        assertEquals(14.1953125f, placed.border.bottom - placed.border.top, .006f)
        val forward = last.copy(right = 96.25f) // Synthetic opposite edge-order contrast.
        assertEquals(NativeFloatBounds(first.left, first.top, forward.right, last.bottom),
            nativeInlineBoxOverlayLtrContainingPadding(first, forward))
        for (scale in listOf(.75f, 1f, 1.5f, 2f)) {
            fun scaled(b: NativeFloatBounds) = NativeFloatBounds(b.left * scale, b.top * scale,
                b.right * scale, b.bottom * scale)
            for (end in listOf(last, forward)) {
                val actual = nativeInlineBoxOverlayLtrContainingPadding(scaled(first), scaled(end))
                val expected = scaled(nativeInlineBoxOverlayLtrContainingPadding(first, end))
                assertEquals(expected, actual)
            }
            assertEquals(scaled(first), nativeInlineBoxOverlayLtrContainingPadding(scaled(first), scaled(first)))
        }
        assertThrows(UnsupportedFloatLayout::class.java) {
            nativeInlineBoxOverlayLtrContainingPadding(first, last.copy(top = 0f, bottom = 2f))
        }
    }
}
