package app.smallthingz.dict

import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.unit.Density
import org.junit.Assert.*
import org.junit.Test

class InlineImageTest {
    @Test fun actionableImagesKeepNamesSeparateFromAuthoredAltAndDecorativeFallbacks() {
        val image = InlineImage("Vraagteken-2.svg", 15)
        for (alt in listOf(null, "", " \t")) {
            val occurrence = image.copy(alt = alt)
            assertEquals("Open image link: Vraagteken-2.svg", inlineImageAccessibilityLabel(occurrence, "Open image link"))
            assertEquals("Image details: Vraagteken-2.svg", inlineImageAccessibilityLabel(occurrence, "Image details"))
            assertEquals(alt, inlineImageAccessibilityLabel(occurrence, null))
            assertEquals(alt, occurrence.alt)
        }
        val authored = image.copy(alt = "Authored alternative", tooltip = "Separate advice")
        assertEquals("Authored alternative", inlineImageAccessibilityLabel(authored, "Open image link"))
        assertEquals("Authored alternative", inlineImageAccessibilityLabel(authored, "Image details"))
        assertEquals("Separate advice", authored.tooltip)
        for (alt in listOf(null, "")) for (state in listOf(InlineImageAssetState.Disabled,
            InlineImageAssetState.Loading, InlineImageAssetState.Failed)) {
            assertNull(inlineImageFallbackText(image.copy(alt = alt), state))
        }
        assertNull(image.alt)
        assertEquals(15L, image.widthPx)
    }

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

    @Test fun outsideBorderPreservesContentDimensionsZeroFontActionsAndAlternativeStates() {
        // Controlled intrinsic ratio, not fetched metadata for the Italian flag.
        val image = InlineImage("Controlled.svg", 40, alt = "", tooltip = "Authored detail", border = true)
        val span = Span("link", "", "File:Controlled.svg", fontScale = 0f, small = true, image = image)
        for (density in listOf(1f, 1.5f, 2f)) {
            for (mime in listOf("image/svg+xml", "image/png")) {
                val content = checkNotNull(inlineImagePixels(image, 100, 50, density, mime))
                assertEquals(InlineImagePixels(40f * density, 20f * density), content)
                assertEquals(content, inlineImagePixels(image.copy(border = false), 100, 50, density, mime))
                assertEquals(content, inlineImagePixels(span.image!!, 100, 50, density, mime))
                assertEquals(content, inlineImageOuterPixels(content, false, density))
                val outer = inlineImageOuterPixels(content, true, density)
                assertEquals(InlineImagePixels(42f * density, 22f * density), outer)
                val font = Density(density, 2f)
                with(font) { assertEquals(outer.width, outer.width.toSp().toPx(), 0f) }
                for (metrics in listOf(InlineImageFontMetrics(-16, 4, 8f, 0), InlineImageFontMetrics(0, 0, 0f, 0))) {
                    val height = inlineImageReservedHeight(metrics, outer.height).toInt()
                    val top = inlineImageDrawTop(metrics, outer.height, height)
                    assertTrue(top >= 0f && top + outer.height <= height)
                    assertEquals(inlineImageDrawTop(metrics, content.height, height), top + density, 0f)
                }
            }
        }
        val huge = checkNotNull(inlineImagePixels(image.copy(widthPx = 0xffff_ffffL), 100, 50, 3f, "image/svg+xml"))
        assertEquals(MaxComputedFontPixels, huge.width, 0f)
        assertEquals(MaxComputedFontPixels + 6f, inlineImageOuterPixels(huge, true, 3f).width, 0f)
        for (bad in listOf(0f, -1f, Float.NaN, Float.POSITIVE_INFINITY)) {
            assertThrows(IllegalArgumentException::class.java) { inlineImageOuterPixels(InlineImagePixels(40f, 20f), true, bad) }
            assertThrows(IllegalArgumentException::class.java) { inlineImageOuterPixels(InlineImagePixels(bad, 20f), true, 1f) }
        }
        assertThrows(IllegalArgumentException::class.java) {
            inlineImageOuterPixels(InlineImagePixels(40f, 20f), true, Float.MAX_VALUE)
        }
        assertEquals("https://it.wiktionary.org/wiki/File%3AControlled.svg", inlineImageLinkUrl(span, "itwiktionary-20261001"))
        assertNull(inlineImageLinkUrl(span.copy(kind = "text", target = ""), "itwiktionary-20261001"))
        for (state in listOf(InlineImageAssetState.Disabled, InlineImageAssetState.Loading, InlineImageAssetState.Failed)) {
            assertNull(inlineImageFallbackText(image, state))
            assertNull(inlineImageFallbackText(image.copy(alt = null), state))
            assertEquals("Alternative", inlineImageFallbackText(image.copy(alt = "Alternative"), state))
        }
        assertEquals("", span.image!!.alt)
        assertEquals("Authored detail", span.image!!.tooltip)
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

    @Test fun retainedOriginalAxesUseCurrentBoundsDensityAndMimeWithoutInventingInitialGeometry() {
        val source = InlineImage("Controlled.png", 120, 90, alt = "Complete alternative", border = true)
        val original = InlineImageKnownGeometry(310, 157, "image/png")
        assertEquals(InlineImagePixels(120f, 61f), original.pixels(source, 1f))
        assertEquals(InlineImagePixels(150f, 76.25f), original.pixels(source, 1.25f))
        assertEquals(InlineImagePixels(152.5f, 78.75f), inlineImageOuterPixels(
            checkNotNull(original.pixels(source, 1.25f)), source.border, 1.25f))
        assertEquals(InlineImagePixels(30f, 15f), original.pixels(source.copy(widthPx = 30, heightPx = 30), 1f))
        assertEquals(InlineImagePixels(33f, 90f), InlineImageKnownGeometry(90, 240, "image/png").pixels(source, 1f))
        val heightOnly = InlineImage("Ratio.svg", heightPx = 80)
        assertNull(InlineImageKnownGeometry(20, 40, null).pixels(heightOnly, 1f))
        assertEquals(InlineImagePixels(40f, 80f), InlineImageKnownGeometry(20, 40, "image/svg+xml").pixels(heightOnly, 1f))
        assertEquals(InlineImagePixels(20f, 40f), InlineImageKnownGeometry(20, 40, "image/png").pixels(heightOnly, 1f))
        for ((width, height) in listOf(0L to 157L, 310L to 0L, -1L to 157L)) {
            assertThrows(IllegalArgumentException::class.java) { InlineImageKnownGeometry(width, height, "image/png") }
        }
        val unknown = InlineImageGeometryState()
        assertNull(unknown[inlineImageAssetKey(source)])
        for (state in listOf(InlineImageAssetState.Disabled, InlineImageAssetState.Loading, InlineImageAssetState.Failed)) {
            assertEquals("Complete alternative", inlineImageFallbackText(source, state))
            assertNull(unknown[inlineImageAssetKey(source)])
        }
        assertEquals(120L, source.widthPx); assertEquals(90L, source.heightPx)
        assertEquals("Complete alternative", source.alt)
    }

    @Test fun retainedAxesSurviveRequestClosureButStaleRequestsCannotReplaceNewAssetMetadata() {
        val known = InlineImageGeometryState()
        val key = inlineImageAssetKey(InlineImage("Controlled.png"))
        val first = Any(); val replacement = Any()
        val original = InlineImageKnownGeometry(310, 157, "image/png")
        val updated = InlineImageKnownGeometry(90, 240, "image/png")
        known.start(key, first)
        assertTrue(known.accept(key, first, original))
        known.start(key, replacement)
        known.finish(key, first) // Closing an older settings/density owner cannot cancel its replacement.
        assertFalse(known.accept(key, first, updated))
        assertEquals(original, known[key])
        assertTrue(known.isCurrent(key, replacement))
        assertTrue(known.accept(key, replacement, updated))
        assertEquals(updated, known[key])
        known.finish(key, replacement)
        assertFalse(known.isCurrent(key, replacement))
        assertFalse(known.accept(key, replacement, original))
        assertEquals(updated, known[key])
        val retry = Any()
        known.start(key, retry)
        assertEquals(updated, known[key])
        assertTrue(known.accept(key, retry, original))
        assertEquals(original, known[key])
    }

    @Test fun retainedAxesStayWithinExactAssetAndCompositionSourceIdentity() {
        val known = InlineImageGeometryState()
        val first = InlineImage("Controlled.svg", 120, svgLanguage = "en")
        val translated = first.copy(svgLanguage = "fr")
        val other = first.copy(file = "Other.svg")
        val key = inlineImageAssetKey(first)
        val token = Any()
        known.start(key, token)
        val original = InlineImageKnownGeometry(310, 157, "image/svg+xml")
        assertTrue(known.accept(key, token, original))
        assertEquals(original, known[inlineImageAssetKey(first.copy(widthPx = 30, heightPx = 30))])
        assertNull(known[inlineImageAssetKey(translated)])
        assertNull(known[inlineImageAssetKey(other)])
        val newSource = InlineImageGeometryState()
        assertNull(newSource[key])
        assertFalse(newSource.accept(key, token, original))
        val next = Any(); newSource.start(key, next)
        val changed = InlineImageKnownGeometry(90, 240, "image/svg+xml")
        assertTrue(newSource.accept(key, next, changed))
        assertEquals(changed, newSource[key])
        assertEquals(original, known[key])
    }
}
