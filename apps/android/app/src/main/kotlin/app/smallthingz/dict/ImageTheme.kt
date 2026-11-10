package app.smallthingz.dict

import android.graphics.ColorFilter
import android.graphics.ColorMatrixColorFilter
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember

/** Ordered CSS invert(1), hue-rotate(180deg), in sRGB; the alpha row is unchanged.
 * https://www.w3.org/TR/filter-effects-1/#elementdef-fecolormatrix
 * BitmapFactory decodes the same raster independently of application theme;
 * no dark color-scheme is applied to the source image before this pixel filter.
 */
internal fun imageDarkModeMatrix(filter: ImageDarkModeFilter?, dark: Boolean): FloatArray? {
    if (!dark || filter == null) return null
    return when (filter) {
        ImageDarkModeFilter.InvertHueRotate180 -> floatArrayOf(
             .574f, -1.430f, -.144f, 0f, 255f,
            -.426f,  -.430f, -.144f, 0f, 255f,
            -.426f, -1.430f,  .856f, 0f, 255f,
                 0f,    0f,     0f, 1f,   0f,
        )
    }
}

@Composable
internal fun rememberInlineImageColorFilter(image: InlineImage): ColorFilter? {
    val dark = LocalReaderDarkTheme.current
    return remember(image.darkModeFilter, dark) {
        imageDarkModeMatrix(image.darkModeFilter, dark)?.let(::ColorMatrixColorFilter)
    }
}
