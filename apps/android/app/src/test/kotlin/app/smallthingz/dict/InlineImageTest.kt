package app.smallthingz.dict

import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.unit.Density
import org.junit.Assert.*
import org.junit.Test

class InlineImageTest {
    @Test fun matchedClientGeometryAndActualMetricMiddleStayAbsoluteUnderZeroAndSmallText() {
        // Original dimensions authenticated by assets01/result.json cee04d6b;
        // these are client-math controls, not an SVG fetch/rendering claim.
        for ((file, original, expected) in listOf(
            Triple("Vraagteken-2.svg", 128L to 214L, InlineImagePixels(15f, 25f)),
            Triple("X mark.svg", 525L to 600L, InlineImagePixels(15f, 17f)),
            Triple("Yes check.svg", 600L to 600L, InlineImagePixels(15f, 15f)))) {
            val image = InlineImage(file, 15)
            assertEquals(expected, inlineImagePixels(image, original.first, original.second, 1f, "image/svg+xml"))
            val zero = Span("text", "", small = true, fontScale = 0f, image = image)
            assertEquals(expected, inlineImagePixels(zero.image!!, original.first, original.second, 1f, "image/svg+xml"))
            assertEquals(15L, zero.image!!.widthPx)
        }
        assertEquals(InlineImagePixels(6f, 20f), inlineImagePixels(InlineImage("Raster.png", 15, 20), 100, 300, 1f, "image/png"))
        assertEquals(InlineImagePixels(15f, 8f), inlineImagePixels(InlineImage("Ratio.svg", 15), 2, 1, 1f, "image/svg+xml"))
        assertEquals(InlineImagePixels(100f, 300f), inlineImagePixels(InlineImage("Raster.png", heightPx = 600), 100, 300, 1f, "image/png"))
        assertEquals(InlineImagePixels(6f, 20f), inlineImagePixels(InlineImage("Raster.png", heightPx = 20), 100, 300, 1f, "image/png"))
        assertEquals(InlineImagePixels(6f, 20f), inlineImagePixels(InlineImage("Known.svg", heightPx = 20), 100, 300, 1f, "image/svg+xml"))
        assertNull(inlineImagePixels(InlineImage("Unknown", heightPx = 20), 100, 300, 1f))
        assertEquals(InlineImagePixels(128f, 214f), inlineImagePixels(InlineImage("Natural.svg"), 128, 214, 1f, "image/svg+xml"))
        val huge = InlineImage("Huge.svg", 0xffff_ffffL, 0xffff_ffffL)
        val projected = checkNotNull(inlineImagePixels(huge, 100, 300, 3f, "image/svg+xml"))
        assertTrue(projected.width > 0f && projected.height > 0f && projected.width <= MaxComputedFontPixels && projected.height <= MaxComputedFontPixels)
        assertEquals(0xffff_ffffL, huge.widthPx)
        val density = Density(2f, 2f)
        val pixels = checkNotNull(inlineImagePixels(InlineImage("Fixed.svg", 15), 128, 214, density.density, "image/svg+xml"))
        with(density) {
            assertEquals(30f, pixels.width.toSp().toPx(), 0f)
            assertEquals(50f, pixels.height.toSp().toPx(), 0f)
        }
        for (metrics in listOf(InlineImageFontMetrics(-16, 4, 8f, 0),
                InlineImageFontMetrics(-16, 4, 8f, -4), InlineImageFontMetrics(0, 0, 0f, 0))) {
            val reserved = inlineImageReservedHeight(metrics, 25f).toInt()
            val baseline = -((metrics.ascent.toLong() + metrics.descent - reserved) / 2L).toFloat()
            val top = inlineImageDrawTop(metrics, 25f, reserved)
            assertEquals(baseline + metrics.baselineShift - metrics.xHeight / 2f, top + 12.5f, 0f)
            assertTrue(top >= 0f && top + 25f <= reserved)
        }
    }

    @Test fun heightOnlySvgUsesOriginalRatioAndKeepsExplicitEmptyAlternativeAndNoLink() {
        // Controlled original dimensions; these are not captured logo metadata
        // or a claim about a source deployment's SVGMaxSize configuration.
        val logo = InlineImage("Wikipedia-logo-v2.svg", heightPx = 40, alt = "")
        for ((height, expected) in listOf(20L to InlineImagePixels(10f, 20f),
                40L to InlineImagePixels(20f, 40f), 80L to InlineImagePixels(40f, 80f))) {
            assertEquals(expected, inlineImagePixels(logo.copy(heightPx = height), 20, 40, 1f, "image/svg+xml"))
        }
        assertEquals(InlineImagePixels(40f, 80f), inlineImagePixels(logo, 20, 40, 2f, " Image/SVG+XML; charset=utf-8 "))
        assertEquals(InlineImagePixels(20f, 40f), inlineImagePixels(logo.copy(heightPx = 80), 20, 40, 1f, "image/png"))
        assertNull(inlineImagePixels(logo, 20, 40, 1f))
        assertNull(inlineImagePixels(logo, 20, 40, 1f, "application/octet-stream"))
        val projected = checkNotNull(inlineImagePixels(logo.copy(heightPx = 0xffff_ffffL), 20, 40, 3f, "image/svg+xml"))
        assertTrue(projected.width > 0f && projected.height > 0f && projected.width <= MaxComputedFontPixels && projected.height <= MaxComputedFontPixels)
        val occurrence = Span("text", "", target = "", image = logo)
        assertEquals("", occurrence.text)
        assertEquals("", occurrence.target)
        assertEquals("", occurrence.image!!.alt)
        assertNull(occurrence.image!!.tooltip)
        assertNull(inlineImageLinkUrl(occurrence, "mnwwiktionary-20261001"))
        for (state in listOf(InlineImageAssetState.Disabled, InlineImageAssetState.Loading, InlineImageAssetState.Failed)) {
            assertNull(inlineImageFallbackText(logo, state))
        }
        assertEquals(40L, logo.heightPx)
        assertNull(logo.widthPx)
    }

    @Test fun canonicalAssetActionsCaptionOwnershipAndEgyptianOffsetsStayIndependent() {
        val image = InlineImage("File:Opaque.svg", 15)
        val span = Span("link", "", "File:File:Opaque.svg", image = image)
        val media = Media(image.file, "image", "Distinct catalogue caption")
        assertEquals("File:File:Opaque.svg", mediaRequestTitle(media, true))
        assertEquals("File:Opaque.svg", mediaRequestTitle(media, false)) // Existing legacy route is unchanged.
        assertEquals("https://he.wiktionary.org/wiki/File%3AFile%3AOpaque.svg", inlineImageLinkUrl(span, "hewiktionary-20261001"))
        assertNull(inlineImageLinkUrl(span, ""))
        assertNull(inlineImageLinkUrl(span.copy(target = "Target"), "hewiktionary-20261001"))
        assertNull(inlineImageLinkUrl(span.copy(kind = "text", target = ""), "hewiktionary-20261001"))
        assertEquals("https://example.org/x", inlineImageLinkUrl(span.copy(kind = "external_link", target = "//example.org/x"), ""))
        assertEquals(mediaKey(media, "hewiktionary-20261001"), mediaKey(media, "hewiktionary-20261002"))
        assertNotEquals(mediaKey(media, "hewiktionary-20261001"), mediaKey(media, "frwiktionary-20261001"))
        val entry = Entry("word", emptyList(), "language", "English", "en", listOf(Section(3, "Body",
            listOf(Block("paragraph", 0, listOf(span))))), emptyList(), media = listOf(media))
        assertEquals(setOf(image.file), entry.separateImageCaptionFiles)
        assertEquals("Distinct catalogue caption", entry.media.single().caption)
        assertEquals(setOf(image.file), inlineMediaFiles(entry))
        val described = span.copy(image = image.copy(alt = "איקס", tooltip = "איקס"))
        for (state in listOf(InlineImageAssetState.Disabled, InlineImageAssetState.Loading, InlineImageAssetState.Failed)) {
            assertEquals("איקס", inlineImageFallbackText(checkNotNull(described.image), state))
            assertNull(inlineImageFallbackText(image.copy(alt = null, tooltip = "Not an alternative"), state))
            assertNull(inlineImageFallbackText(image.copy(alt = ""), state))
        }
        val unframed = entry.copy(sections = listOf(Section(3, "Body", listOf(Block("paragraph", 0, listOf(described))))),
            media = listOf(media.copy(caption = "איקס")))
        assertTrue(unframed.separateImageCaptionFiles.isEmpty())
        val legacy = Span("link", "Legacy caption", span.target, classes = "wikidict-media")
        val both = entry.copy(sections = listOf(Section(3, "Body", listOf(Block("paragraph", 0, listOf(span)),
            Block("paragraph", 0, listOf(legacy))))))
        assertEquals(setOf(image.file), both.legacyImageFiles)
        assertEquals(setOf(image.file), both.separateImageCaptionFiles)
        assertEquals(setOf("Legacy caption"), both.legacyImageCaptions[image.file])
        assertTrue(both.copy(media = listOf(media.copy(caption = "Legacy caption"))).separateImageCaptionFiles.isEmpty())
        val glyphs = String(Character.toChars(0x13000)) + String(Character.toChars(0x13001))
        val logical = listOf(Span("text", glyphs, direction = "auto", classes = "Egyp"), span.copy(direction = "rtl"))
        val runs = egyptianTextRuns(logical)
        assertEquals(1, runs.single().start); assertEquals(5, runs.single().end)
        val annotated = buildAnnotatedString {
            append('\u2068'); append(glyphs); append('\u2069'); append('\u2067')
            appendInlineContent("compiled-image-1", InlineImageReplacement); append('\u2069')
        }
        val mapped = egyptianInlineText(annotated, runs, false)
        val marker = mapped.getStringAnnotations(0, mapped.length).single { it.item == "compiled-image-1" }
        assertEquals(9, marker.start); assertEquals(10, marker.end)
        assertEquals(InlineImageReplacement, mapped.text.substring(marker.start, marker.end))
        assertEquals(listOf(span, span), compactSpans(listOf(span, span)))
    }
}
