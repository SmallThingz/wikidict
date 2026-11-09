package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Contract07 source-derived logical axes, independent of transformed bitmap dimensions. */
class FigureSizingTest {
    private fun figure(policy: FigureSizingPolicy, width: Long? = 400, height: Long? = null,
        format: FigureFormat = if (policy == FigureSizingPolicy.Intrinsic ||
            policy == FigureSizingPolicy.OriginalWidthWithHeightBound) FigureFormat.Framed else FigureFormat.Thumbnail): Figure {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        return Figure(Span("link", "", "Retained-target", targetFragment = "",
            image = InlineImage("Image.svg", widthPx = width, heightPx = height, alt = "Authored alt")),
            format, FigurePlacement.Center, FigureClear.None, edges, edges, edges,
            .884f, StyleLength(StyleLengthUnit.Em, 1.2376f), FigureColor.NativeTheme, FigureBorder.None,
            FigureColor.Transparent, FigureBorder.None, FigureColor.NativeTheme, FigureColor.Transparent,
            caption = listOf(Span("text", "Retained caption")), sizing = policy)
    }
    private fun size(value: Figure, w: Long = 512, h: Long = 420) = figureSourceSize(value, w, h)
    private fun expected(w: ULong, h: ULong, actual: FigureSourceSize) = assertEquals(FigureSourceSize(w, h), actual)

    @Test fun requiredPolicyRejectsContradictoryFormatAndMissingBoundsWithoutChangingOccurrence() {
        val intrinsic = figure(FigureSizingPolicy.Intrinsic, 400, 100)
        expected(512uL, 420uL, size(intrinsic))
        assertEquals(400L, intrinsic.imageSpan.image!!.widthPx)
        assertEquals(100L, intrinsic.imageSpan.image!!.heightPx)
        assertEquals(EntryLink("Retained-target", ""), intrinsic.imageSpan.entryLink())
        assertEquals("Authored alt", intrinsic.imageSpan.image!!.alt)
        assertEquals("Retained caption", textOf(intrinsic.caption))
        for (policy in FigureSizingPolicy.entries) {
            val correct = if (policy == FigureSizingPolicy.Intrinsic || policy == FigureSizingPolicy.OriginalWidthWithHeightBound)
                FigureFormat.Framed else FigureFormat.Thumbnail
            val wrong = if (correct == FigureFormat.Framed) FigureFormat.Thumbnail else FigureFormat.Framed
            figure(policy, 400, 100, correct)
            assertThrows(IllegalArgumentException::class.java) { figure(policy, 400, 100, wrong) }
        }
        figure(FigureSizingPolicy.Intrinsic, null, null)
        figure(FigureSizingPolicy.OriginalWidthWithHeightBound, null, 100)
        assertThrows(IllegalArgumentException::class.java) { figure(FigureSizingPolicy.OriginalWidthWithHeightBound, 400, null) }
        for (policy in listOf(FigureSizingPolicy.RequestedFit, FigureSizingPolicy.RequestedFitCapOriginalWidth))
            assertThrows(IllegalArgumentException::class.java) { figure(policy, null, 100) }
        for (bad in listOf(0L, -1L, 0x1_0000_0000L)) {
            assertThrows(IllegalArgumentException::class.java) { figure(FigureSizingPolicy.Intrinsic, bad, 1) }
            assertThrows(IllegalArgumentException::class.java) { figure(FigureSizingPolicy.Intrinsic, 1, bad) }
        }
    }

    @Test fun requestedPoliciesCapBeforeHeightFitAndKeepAllFourSourceVectors() {
        for (policy in listOf(FigureSizingPolicy.RequestedFit, FigureSizingPolicy.RequestedFitCapOriginalWidth))
            expected(400uL, 328uL, size(figure(policy)))
        expected(1024uL, 840uL, size(figure(FigureSizingPolicy.RequestedFit, 1024)))
        expected(512uL, 420uL, size(figure(FigureSizingPolicy.RequestedFitCapOriginalWidth, 1024)))
        expected(732uL, 600uL, size(figure(FigureSizingPolicy.RequestedFit, 1200, 600)))
        // Fitting first would leave a600-high result. The cap makes height600 non-dominating.
        expected(512uL, 420uL, size(figure(FigureSizingPolicy.RequestedFitCapOriginalWidth, 1200, 600)))
    }

    @Test fun originalWidthPolicyUsesTheSameFitAndRetainsHeightOnlyWhenDominating() {
        expected(122uL, 100uL, size(figure(FigureSizingPolicy.OriginalWidthWithHeightBound, null, 100)))
        expected(122uL, 100uL, size(figure(FigureSizingPolicy.OriginalWidthWithHeightBound, 1, 100)))
        expected(512uL, 420uL, size(figure(FigureSizingPolicy.OriginalWidthWithHeightBound, 1200, 600)))
        expected(512uL, 420uL, size(figure(FigureSizingPolicy.OriginalWidthWithHeightBound, null, 420)))
    }

    @Test fun sourceRoundingPreservesLogicalZeroAndRetainedHeightAfterWidthMinimum() {
        expected(1uL, 1uL, size(figure(FigureSizingPolicy.RequestedFit, 10, 1), 5, 4))
        expected(1uL, 1uL, size(figure(FigureSizingPolicy.RequestedFit, 10, 1), 1, 1000))
        expected(1uL, 1uL, size(figure(FigureSizingPolicy.RequestedFit, 1), 2, 1))
        expected(1uL, 0uL, size(figure(FigureSizingPolicy.RequestedFit, 1), 3, 1))
        expected(1uL, 0uL, size(figure(FigureSizingPolicy.RequestedFitCapOriginalWidth, 1), 4000, 1))
    }

    @Test fun unsignedProductsRemainExactBeyondSignedLongWithoutSaturation() {
        val maximum = 0xffff_ffffL
        expected(0xffff_ffffuL, 0xffff_ffffuL,
            size(figure(FigureSizingPolicy.RequestedFit, maximum), maximum, maximum))
        expected(0xffff_fffeuL, 0xffff_fffeuL,
            size(figure(FigureSizingPolicy.RequestedFit, maximum, maximum - 1), maximum, maximum))
        expected(0xffff_ffffuL, 18_446_744_065_119_617_025uL,
            size(figure(FigureSizingPolicy.RequestedFit, maximum), 1, maximum))
        assertThrows(UnsupportedFloatLayout::class.java) {
            figureImagePixels(figure(FigureSizingPolicy.RequestedFit, maximum), 1, maximum, .000000001f)
        }
    }

    @Test fun densityNeverReconstructsLogicalMapAxesAndZeroHasNoHitPlane() {
        val value = figure(FigureSizingPolicy.RequestedFit, 400)
        assertEquals(FigurePixels(600f, 492f, 400.0, 328.0), figureImagePixels(value, 512, 420, 1.5f))
        val fractional = figureImagePixels(figure(FigureSizingPolicy.RequestedFit, 3), 5, 3, 1.5f)
        assertEquals(FigurePixels(5f, 3f, 3.0, 2.0), fractional)
        assertNotEquals(fractional.sourceWidth, fractional.width.toDouble() / 1.5)
        val zero = figureImagePixels(figure(FigureSizingPolicy.RequestedFit, 1), 3, 1, 1f)
        assertEquals(FigurePixels(1f, 0f, 1.0, 0.0), zero)
        val action = ImageMapAction(ImageMapActionKind.Internal, "Explicit-map-target", null, "Map")
        val map = ImageMap(ImageMapDescription.None, emptyList(), action)
        assertNull(PreparedImageMap.prepare(map, 3, 1, zero.sourceWidth!!, zero.sourceHeight!!))
    }

    @Test fun unavailableOriginalsAndPlatformLimitsDoNotGuessOrClampGeometry() {
        val value = figure(FigureSizingPolicy.RequestedFit)
        for (bad in listOf(0L, -1L, 0x1_0000_0000L)) {
            assertThrows(UnsupportedFloatLayout::class.java) { size(value, bad, 420) }
            assertThrows(UnsupportedFloatLayout::class.java) { size(value, 512, bad) }
        }
        for (density in listOf(0f, -1f, Float.NaN, Float.POSITIVE_INFINITY))
            assertThrows(IllegalArgumentException::class.java) { figureImagePixels(value, 512, 420, density) }
        assertThrows(UnsupportedFloatLayout::class.java) { figureImagePixels(value, 512, 420, Float.MAX_VALUE) }
        assertThrows(UnsupportedFloatLayout::class.java) {
            figureImagePixels(figure(FigureSizingPolicy.Intrinsic), 0xffff_ffffL, 1, 1f)
        }
        assertEquals("Retained caption", textOf(value.caption))
        assertEquals(EntryLink("Retained-target", ""), value.imageSpan.entryLink())
    }
}
