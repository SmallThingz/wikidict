package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

class StaticPosterTest {
    private val identity = StaticPoster(StaticPosterPolicy.ThreeDStlV1, "3D", "a".repeat(40), "2026-01-02T03:04:05Z")
    private fun image(poster: StaticPoster? = identity) = InlineImage("Controlled.stl", 250, 188, "Authored alternative", staticPoster = poster)
    private class Wire {
        val out = ByteArrayOutputStream()
        fun byte(value: Int) { out.write(value) }
        fun int(value: Int) { repeat(4) { byte(value ushr (it * 8)) } }
        fun text(value: String) { val b = value.encodeToByteArray(); int(b.size); out.write(b) }
    }
    private fun fixture(version: Int = 77, tag: Int = 2, policy: Int = 0, nested: Boolean = false): ByteArray = Wire().run {
        fun span() {
            byte(1); byte(0); byte(0); text(""); text("File:Controlled.stl"); repeat(5) { text("") }
            repeat(3) { byte(0) }
            byte(tag)
            if (tag != 0) {
                text("Controlled.stl"); byte(3); int(250); int(188)
                if (tag == 2) { byte(policy); text("3D"); text(identity.fileSha1); text(identity.fileTimestamp) }
            }
            byte(0); byte(0)
        }
        fun block(container: Boolean) {
            byte(if (container) 13 else 0); byte(0); byte(0)
            int(if (container) 0 else 1); if (!container) span()
            byte(0); text(""); text(""); byte(0); text(""); text(""); repeat(4) { byte(0) }
        }
        byte(68); byte(80); byte(82); byte(version)
        int(if (nested) 0 else 1); if (!nested) span()
        int(if (nested) 1 else 0)
        if (nested) {
            byte(2); text("Controlled"); text(""); text(""); int(1); block(true)
            int(0); int(1); block(false) // M style u32 and the real Container child
        }
        int(0); int(0); int(if (nested) 1 else 0); if (nested) int(0) // preamble, lexemes, other sections
        int(0); int(1); text("Controlled.stl"); byte(0); text("")
        out.toByteArray()
    }
    private fun decode(bytes: ByteArray) = BlobDecoder.decode(bytes, "word", "language", "English", "en")

    @Test fun mTagTailAndRecursiveSpanRetainIdentityAndOldTagsRemainExact() {
        val top = decode(fixture()).displayTitle.single()
        assertEquals(identity, top.image!!.staticPoster)
        assertEquals("File:Controlled.stl", top.target)
        val nested = decode(fixture(nested = true)).sections.single().blocks.single().container!!.blocks.single().spans.single()
        assertEquals(top, nested)
        for (tag in listOf(0, 1)) assertEquals(decode(fixture(tag = tag)).displayTitle,
            decode(fixture(version = 76, tag = tag)).displayTitle)
        for (version in listOf(75, 76)) assertThrows(Exception::class.java) { decode(fixture(version = version)) }
        assertThrows(Exception::class.java) { decode(fixture(tag = 3)) }
        assertThrows(Exception::class.java) { decode(fixture(policy = 1)) }
        val valid = fixture()
        for (length in valid.indices) assertThrows(Exception::class.java) { decode(valid.copyOf(length)) }
    }

    @Test fun posterModelRefusesIdentityAxesAndIncompatibleImagePolicies() {
        assertThrows(IllegalArgumentException::class.java) { image().copy(heightPx = 141) }
        assertThrows(IllegalArgumentException::class.java) { image().copy(file = "Controlled.svg") }
        assertThrows(IllegalArgumentException::class.java) { image().copy(svgLanguage = "en") }
        assertThrows(IllegalArgumentException::class.java) { image().copy(darkModeFilter = ImageDarkModeFilter.InvertHueRotate180) }
        assertThrows(IllegalArgumentException::class.java) { identity.copy(fileSha1 = "A".repeat(40)) }
        for (timestamp in listOf("2026-02-29T00:00:00Z", "0000-01-01T00:00:00Z", "2026-01-01T24:00:00Z", "2026-01-01T00:00:00.1Z"))
            assertThrows(IllegalArgumentException::class.java) { identity.copy(fileTimestamp = timestamp) }
        assertEquals("", identity.copy(label = "").label)
        assertEquals("Image layout unavailable. Authored alternative 3D",
            inlineImageFallbackText(image(), InlineImageAssetState.LayoutUnavailable))
    }

    @Test fun resourceRequiresOriginalIdentityAndFourByThreePngWithoutOriginalFallback() {
        val request = StaticPosterRequest(1f, listOf(RasterImageOccurrence(image(), FigureSizingPolicy.RequestedFit)))
        assertEquals(250, request.requestWidth)
        request.validateIdentity("File:Controlled.stl", identity.fileSha1, identity.fileTimestamp, "application/sla", "3D")
        val url = "https://upload.wikimedia.org/wikipedia/commons/thumb/a/aa/Controlled.stl/250px-Controlled.stl.png"
        assertEquals(SvgRasterDemand(250, 188), request.validateRaster(url, "image/png", 250, 188))
        assertThrows(IllegalArgumentException::class.java) { request.validateIdentity("File:Other.stl", identity.fileSha1, identity.fileTimestamp, "application/sla", "3D") }
        assertThrows(IllegalArgumentException::class.java) { request.validateIdentity("File:Controlled.stl", "b".repeat(40), identity.fileTimestamp, "application/sla", "3D") }
        assertThrows(IllegalArgumentException::class.java) { request.validateIdentity("File:Controlled.stl", identity.fileSha1, "2026-01-02T03:04:06Z", "application/sla", "3D") }
        for ((mime, width, height) in listOf(Triple("application/sla", 250, 188), Triple("image/png", 250, 141), Triple("image/png", 249, 187)))
            assertThrows(IllegalArgumentException::class.java) { request.validateRaster(url, mime, width, height) }
        for (bad in listOf(url.removeSuffix(".png"), url.replace("upload.wikimedia.org", "example.org"), "$url?original=1"))
            assertThrows(IllegalArgumentException::class.java) { request.validateRaster(bad, "image/png", 250, 188) }
        val scaled = StaticPosterRequest(1.5f, listOf(RasterImageOccurrence(image())))
        assertEquals(376, scaled.requestWidth) // both scaled HTML axes must fit after PHP rounding
        assertNotEquals(request.cacheSuffix, scaled.cacheSuffix)
        assertNotEquals(inlineImageAssetKey(image()), inlineImageAssetKey(image(identity.copy(fileSha1 = "b".repeat(40)))))
    }

    private fun figure(): Figure {
        val zero = StyleLength(StyleLengthUnit.Px, 0f); val three = zero.copy(value = 3f)
        val padding = StyleEdges(zero, zero.copy(value = 6f), zero.copy(value = 6f), zero.copy(value = 6f))
        return Figure(FigureContent.Image(Span("link", "", "File:Controlled.stl", image = image()), FigureSizingPolicy.RequestedFit),
            FigureFormat.Thumbnail, FigurePlacement.FloatRight, FigureClear.Both, StyleEdges(three, zero, three, three),
            StyleEdges(three, three, three, three), padding, 1f, StyleLength(StyleLengthUnit.Em, 1.4f),
            FigureColor.Transparent, FigureBorder.None, FigureColor.Transparent,
            FigureBorder.Solid(zero.copy(value = 1f), FigureColor.Rgb("#000000")), FigureColor.NativeTheme, FigureColor.Transparent)
    }
    @Test fun rootViewportPolicyAndActualParentFitRemainIndependentWithEmptyCaptionPadding() {
        val wide = figure()
        assertEquals(FigurePlacement.Center, staticPosterScreenFigure(wide, 639.0).placement)
        for (viewport in listOf(639.5, 640.0)) assertEquals(FigurePlacement.FloatRight, staticPosterScreenFigure(wide, viewport).placement)
        assertEquals(FigureClear.Both, staticPosterScreenFigure(wide, 639.0).clear)
        assertEquals(3f, staticPosterScreenFigure(wide, 639.0).captionPadding.bottom.value, 0f)
        val natural = figureBoxMetrics(wide, figureImagePixels(wide, 5120, 2880, 1f), 1f, 16f)
        assertEquals(250f, natural.image.width, 0f); assertEquals(188f, natural.image.height, 0f)
        val small = staticPosterFitMetrics(natural, 108f)
        assertEquals(100f, small.image.width, 0f); assertEquals(75.2f, small.image.height, 0.001f)
        assertEquals(108, small.width)
        assertEquals(natural, staticPosterFitMetrics(natural, 500f))
        val exclusion = staticPosterCaptionExclusion(100, 1f)
        assertEquals(NativeFloatBounds(82f, 0f, 100f, 11f), exclusion.outer)
        assertEquals("3D A\u00a0B", staticPosterPaintedLabel("  3D\t A\u00a0B \n"))
        assertEquals("", staticPosterPaintedLabel(" \t\n"))
        val table = Table(emptyList(), listOf(listOf(Cell(listOf(Span("text", "Cell body")), false, 1, 1))))
        val structured = wide.copy(captionBlocks = listOf(Block("table", 0, emptyList(), table = table)))
        assertNotNull(staticPosterCaptionUnavailable(structured, 640.0))
        assertNull(staticPosterCaptionUnavailable(structured, 639.0))
        assertEquals("Cell body", structured.captionBlocks!!.single().table!!.rows.single().single().spans.single().text)
    }
}
