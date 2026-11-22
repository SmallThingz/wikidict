package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Source-only native admission/range controls; device controls own actual focus and image ink. */
class NativeImageLinkPaintTest {
    private val paint = LinkPaint(
        normal = FigureLinkState("#102030", true), hover = FigureLinkState("#203040", false),
        active = FigureLinkState("#304050", true), hoverActive = FigureLinkState("#405060", false),
        visited = FigureLinkState("#506070", false), visitedHover = FigureLinkState("#607080", true),
        visitedActive = FigureLinkState("#708090", false), visitedHoverActive = FigureLinkState("#8090a0", true),
        underlineOnFocus = true)

    private fun image(kind: String = "link", target: String = "File:Arrowyellow.png",
        direction: String = "", alt: String? = null) = Span(kind, "", target,
        image = InlineImage("Arrowyellow.png", widthPx = 30, heightPx = 30, alt = alt),
        direction = direction, foreground = paint.normal.foreground, underline = paint.normal.underline,
        linkPaint = paint)

    @Test fun replacedActionsNeverEnterGlyphPaintRangesAndKeepNeighborOffsets() {
        val first = Span("link", "A", "First", trail = "!", direction = "rtl", linkPaint = paint,
            foreground = paint.normal.foreground, underline = paint.normal.underline)
        val picture = image(direction = "ltr")
        val last = Span("external_link", "B", "https://example.invalid/path", trail = "?", linkPaint = paint,
            foreground = paint.normal.foreground, underline = paint.normal.underline)
        val source = listOf(first, picture, Span("line_break", ""), last)
        val ranges = nativeCaptionLinkRanges(source)
        assertEquals(listOf(0, 3), ranges.map { it.index })
        assertEquals(listOf(0 to 4, 8 to 10), ranges.map { it.start to it.end })
        assertEquals(10, source.nativeLogicalLength())
        assertSame(first, ranges[0].span)
        assertSame(last, ranges[1].span)
        assertTrue(nativeImageLinkPaintSupported(picture))
        assertNull(ordinaryLinkPaintUnavailable(source))
        assertEquals(source, compactSpans(source))
        assertSame(paint, picture.linkPaint)
        assertTrue(picture.underline) // Kept as a source checksum, never a bitmap underline.
        assertEquals(InlineImage("Arrowyellow.png", 30, 30), picture.image)
    }

    @Test fun validImageModelDoesNotWaiveNativeUrlAdmissionOrChangeNullPolicy() {
        for (valid in listOf(image(), image(alt = ""), image(target = "Other", direction = "auto"),
            image(target = "Other").copy(targetFragment = "section"),
            image("external_link", "https://example.invalid/image#part"),
            image("external_link", "//example.invalid/image"))) {
            assertTrue(nativeImageLinkPaintSupported(valid))
            assertNull(ordinaryLinkPaintUnavailable(listOf(valid)))
            assertTrue(nativeCaptionLinkRanges(listOf(valid)).isEmpty())
        }
        for (target in listOf("javascript:alert(1)", "https:///missing-host", "https://example.invalid:99999/a")) {
            val unsupported = image("external_link", target)
            assertFalse(nativeImageLinkPaintSupported(unsupported))
            assertEquals(NativeOrdinaryLinkPaintUnavailable, ordinaryLinkPaintUnavailable(listOf(unsupported)))
            assertEquals(target, unsupported.target)
            assertSame(paint, unsupported.linkPaint)
            assertNull(ordinaryLinkPaintUnavailable(listOf(unsupported.copy(linkPaint = null))))
        }
        val emptyTextAction = Span("link", "", "Target", linkPaint = paint,
            foreground = paint.normal.foreground, underline = paint.normal.underline)
        assertEquals(NativeOrdinaryLinkPaintUnavailable, ordinaryLinkPaintUnavailable(listOf(emptyTextAction)))
        assertFalse(nativeImageLinkPaintSupported(emptyTextAction))
    }

    @Test fun descriptionPagePolicyNeedsSourceEditionAndKeepsItsExplicitFragment() {
        val source = image().copy(targetFragment = "source part")
        val edition = "mgwiktionary-20261001"
        assertEquals("https://mg.wiktionary.org/wiki/File%3AArrowyellow.png#source%20part",
            inlineImageLinkUrl(source, edition))
        assertTrue(nativeImageLinkPaintSupported(source, edition))
        assertNull(ordinaryLinkPaintUnavailable(listOf(source), edition))
        for (unknown in listOf("", "unknown")) {
            assertNull(inlineImageLinkUrl(source, unknown))
            assertFalse(nativeImageLinkPaintSupported(source, unknown))
            assertEquals(NativeOrdinaryLinkPaintUnavailable,
                ordinaryLinkPaintUnavailable(listOf(source), unknown))
            assertNull(ordinaryLinkPaintUnavailable(listOf(source.copy(linkPaint = null)), unknown))
            assertNull(ordinaryLinkPaintUnavailable(listOf(image(target = "Dictionary target")), unknown))
            assertNull(ordinaryLinkPaintUnavailable(listOf(
                image("external_link", "https://example.invalid/image")), unknown))
        }
        assertEquals("File:Arrowyellow.png", source.target)
        assertEquals("source part", source.targetFragment)
        assertSame(paint, source.linkPaint)
    }
}
