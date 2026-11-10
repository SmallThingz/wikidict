package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Private coefficient/selection controls; native Canvas pixel proof remains separate and unrun. */
class ImageThemeDesignTest {
    private fun filtered(red: Float, green: Float, blue: Float, alpha: Float): FloatArray {
        val matrix = checkNotNull(imageDarkModeMatrix(ImageDarkModeFilter.InvertHueRotate180, true))
        val channels = floatArrayOf(red, green, blue, alpha)
        return FloatArray(4) { row ->
            (matrix[row * 5 + 4] + (0..3).sumOf { (matrix[row * 5 + it] * channels[it]).toDouble() }.toFloat())
                .coerceIn(0f, 255f)
        }
    }

    @Test fun oldImagesAndEffectiveLightModeHaveNoFilter() {
        assertNull(imageDarkModeMatrix(null, false))
        assertNull(imageDarkModeMatrix(null, true))
        assertNull(imageDarkModeMatrix(ImageDarkModeFilter.InvertHueRotate180, false))
    }

    @Test fun darkFilterUsesOrderedInvertThenHueAndPreservesAlpha() {
        assertArrayEquals(floatArrayOf(255f, 255f, 255f, 73f), filtered(0f, 0f, 0f, 73f), .001f)
        assertArrayEquals(floatArrayOf(0f, 0f, 0f, 255f), filtered(255f, 255f, 255f, 255f), .001f)
        assertArrayEquals(floatArrayOf(255f, 146.37f, 146.37f, 128f), filtered(255f, 0f, 0f, 128f), .002f)
        assertArrayEquals(floatArrayOf(127f, 127f, 127f, 0f), filtered(128f, 128f, 128f, 0f), .001f)
    }
}
