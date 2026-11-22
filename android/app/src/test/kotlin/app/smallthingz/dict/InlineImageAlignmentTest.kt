package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Source-only API06 controls; these do not authenticate an image or its source CSS. */
class InlineImageAlignmentTest {
    @Test fun nullAndExplicitMiddleHaveIdenticalMetricAndPlaceholderGeometry() {
        for (metrics in listOf(InlineImageFontMetrics(-16, 4, 8f, 0),
            InlineImageFontMetrics(-31, 9, 13f, -7), InlineImageFontMetrics(0, 0, 0f, 0))) {
            for (height in listOf(1f, 15.5f, 32f, 101f)) {
                val expected = metrics.baselineShift - (height + metrics.xHeight) / 2f
                assertEquals(expected, inlineImageInkTop(metrics, height), 0f)
                assertEquals(expected, inlineImageInkTop(metrics, height, InlineImageVerticalAlign.Middle), 0f)
                val oldHeight = inlineImageReservedHeight(metrics, height)
                assertEquals(oldHeight, inlineImageReservedHeight(metrics, height, InlineImageVerticalAlign.Middle), 0f)
                assertEquals(inlineImageDrawTop(metrics, height, oldHeight.toInt()),
                    inlineImageDrawTop(metrics, height, oldHeight.toInt(), InlineImageVerticalAlign.Middle), 0f)
            }
        }
    }

    @Test fun baselineEndsAtShiftedBaselineAndReserveContainsTheCompleteOuterImage() {
        for (metrics in listOf(InlineImageFontMetrics(-16, 4, 8f, 0),
            InlineImageFontMetrics(-31, 9, 13f, -7), InlineImageFontMetrics(0, 0, 0f, 0))) {
            for (density in listOf(1f, 1.5f, 2f)) for (border in listOf(false, true)) {
                val content = InlineImagePixels(30f * density, 30f * density)
                val outer = inlineImageOuterPixels(content, border, density)
                val top = inlineImageInkTop(metrics, outer.height, InlineImageVerticalAlign.Baseline)
                assertEquals(metrics.baselineShift.toFloat(), top + outer.height, 0f)
                val reserved = inlineImageReservedHeight(metrics, outer.height, InlineImageVerticalAlign.Baseline).toInt()
                val boxBaseline = -((metrics.ascent.toLong() + metrics.descent - reserved) / 2L).toFloat()
                val drawTop = inlineImageDrawTop(metrics, outer.height, reserved, InlineImageVerticalAlign.Baseline)
                assertEquals(boxBaseline + metrics.baselineShift, drawTop + outer.height, 0f)
                assertTrue(drawTop >= 0f)
                assertTrue(drawTop + outer.height <= reserved)
                // The outer bottom, including the authored border, is aligned once.
                if (border) assertEquals(density, boxBaseline + metrics.baselineShift -
                    (drawTop + density + content.height), 0f)
            }
        }
    }

    @Test fun explicitAlignmentDoesNotChangeIntrinsicAxesOrAssetIdentity() {
        val old = InlineImage("Controlled.png", 30, 30, alt = "Retained alt", tooltip = "Retained advice", border = true)
        for (alignment in listOf(null, InlineImageVerticalAlign.Middle, InlineImageVerticalAlign.Baseline)) {
            val image = old.copy(verticalAlign = alignment)
            assertEquals(inlineImageAssetKey(old), inlineImageAssetKey(image))
            assertEquals(inlineImagePixels(old, 128, 128, 1.5f, "image/png"),
                inlineImagePixels(image, 128, 128, 1.5f, "image/png"))
            assertEquals("Retained alt", image.alt)
            assertEquals("Retained advice", image.tooltip)
            assertTrue(image.border)
        }
    }
}
