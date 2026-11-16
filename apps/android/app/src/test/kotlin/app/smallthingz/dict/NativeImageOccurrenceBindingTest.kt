package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativeImageOccurrenceBindingTest {
    @Test fun normalizedEmUsesOriginalBodyOnceWhilePixelsFollowImageDensity() {
        // Synthetic normalized input: no claim about the actual UR/ID issuer tuple.
        val source = InlineImageOccurrenceLayout(SignedContainerMargin(StyleLengthUnit.Em, -.5f),
            SignedContainerMargin(StyleLengthUnit.Px, -1f), StyleLength(StyleLengthUnit.Px, 1f),
            StyleLength(StyleLengthUnit.Em, .54f))
        val first = nativeImageOccurrencePlacement(source, 20f, 2f)!!
        assertEquals(-10f, first.translationX, 0f)
        assertEquals(-2f, first.translationY, 0f)
        assertEquals(2f, first.paddingLeft, 0f)
        assertEquals(10.8f, first.paddingRight, .000001f)
        val bodyZoom = nativeImageOccurrencePlacement(source, 30f, 2f)!!
        assertEquals(-15f, bodyZoom.translationX, 0f)
        assertEquals(-2f, bodyZoom.translationY, 0f)
        assertEquals(2f, bodyZoom.paddingLeft, 0f)
        assertEquals(16.2f, bodyZoom.paddingRight, .000002f)
        val density = nativeImageOccurrencePlacement(source, 20f, 3f)!!
        assertEquals(first.translationX, density.translationX, 0f)
        assertEquals(-3f, density.translationY, 0f)
        assertEquals(3f, density.paddingLeft, 0f)
        assertEquals(first.paddingRight, density.paddingRight, 0f)
        assertEquals(-.5f, source.x.value, 0f)
        assertEquals(.54f, source.paddingRight.value, 0f)
    }

    @Test fun zeroBodyAndZeroOccurrenceKeepPositionedPresenceWithoutInventingAdvance() {
        val zero = StyleLength(StyleLengthUnit.Em, 0f)
        val empty = InlineImageOccurrenceLayout(zero, zero, zero, zero)
        assertNotNull(nativeImageOccurrencePlacement(empty, 0f, 1f))
        assertEquals(NativeImageOccurrencePlacement(0f, 0f, 0f, 0f),
            nativeImageOccurrencePlacement(empty, 20f, 2f))
        val source = InlineImageOccurrenceLayout(SignedContainerMargin(StyleLengthUnit.Px, -10f),
            SignedContainerMargin(StyleLengthUnit.Em, -2f), zero, StyleLength(StyleLengthUnit.Em, .4f))
        val zeroBody = nativeImageOccurrencePlacement(source, 0f, 2f)!!
        assertEquals(-20f, zeroBody.translationX, 0f)
        assertEquals(0f, zeroBody.translationY, 0f)
        assertEquals(0f, zeroBody.paddingLeft, 0f)
        assertEquals(0f, zeroBody.paddingRight, 0f)
        assertNull(nativeImageOccurrencePlacement(null, Float.NaN, Float.NaN))
    }

    @Test fun unavailableBasesAndOverflowRefuseBeforeImageGeometryIsPublished() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val source = InlineImageOccurrenceLayout(zero, zero, zero, zero)
        for ((body, density) in listOf(Float.NaN to 1f, Float.POSITIVE_INFINITY to 1f,
            -1f to 1f, 20f to 0f, 20f to -1f, 20f to Float.POSITIVE_INFINITY)) {
            val failure = runCatching { nativeImageOccurrencePlacement(source, body, density) }.exceptionOrNull()
            assertTrue(failure is UnsupportedFloatLayout)
        }
        val large = source.copy(x = SignedContainerMargin(StyleLengthUnit.Px, -Float.MAX_VALUE))
        assertTrue(runCatching { nativeImageOccurrencePlacement(large, 20f, 2f) }.exceptionOrNull() is UnsupportedFloatLayout)
        val wide = source.copy(paddingRight = StyleLength(StyleLengthUnit.Em, Float.MAX_VALUE))
        assertTrue(runCatching { nativeImageOccurrencePlacement(wide, 20f, 2f) }.exceptionOrNull() is UnsupportedFloatLayout)
        assertEquals(-Float.MAX_VALUE, large.x.value, 0f)
        assertEquals(Float.MAX_VALUE, wide.paddingRight.value, 0f)
    }

    @Test fun terminalOccurrenceFallbackRetainsLaterOrdinaryRequestForTheSameAsset() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val layout = InlineImageOccurrenceLayout(zero, zero, zero, zero)
        val ordinary = InlineImage("Same.svg", widthPx = 12, alt = "Original ordinary alt")
        val positioned = ordinary.copy(alt = "Original positioned alt", occurrenceLayout = layout)
        val other = InlineImage("Other.svg", widthPx = 12, alt = "Original other alt")
        val images = listOf(positioned, ordinary, other)
        assertEquals(inlineImageAssetKey(ordinary), inlineImageAssetKey(positioned))
        val normal = nativeInlineImageRequests(images, false)
        assertEquals(2, normal.size)
        assertSame(positioned, normal[0]); assertSame(other, normal[1])
        val terminal = nativeInlineImageRequests(images, true)
        assertEquals(2, terminal.size)
        assertSame(ordinary, terminal[0]); assertSame(other, terminal[1])
        assertSame(ordinary, nativeInlineImageRequests(listOf(ordinary, positioned), true).single())
        assertTrue(nativeInlineImageRequests(listOf(positioned), true).isEmpty())
        assertSame(positioned, images[0]); assertSame(ordinary, images[1])
        assertSame(layout, positioned.occurrenceLayout)
        assertEquals("Original positioned alt", positioned.alt)
        assertEquals("Original ordinary alt", ordinary.alt)
    }
}
