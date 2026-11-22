package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.RectF
import android.text.Spanned

/** Presence, including four zero values, establishes the relative-positioned paint phase. */
internal data class NativeImageOccurrencePlacement(
    val translationX: Float,
    val translationY: Float,
    val paddingLeft: Float,
    val paddingRight: Float,
) {
    init {
        require(translationX.isFinite() && translationY.isFinite())
        require(paddingLeft.isFinite() && paddingLeft >= 0f && paddingRight.isFinite() && paddingRight >= 0f)
        require(listOf(translationX, translationY, paddingLeft, paddingRight).all {
            kotlin.math.abs(it) <= TablePixelLimit
        })
    }
}

/** The reader-owned image is the only replacement admitted by the Float row adapter.
 * Installed span ranges own current source coordinates; these IDs retain original occurrence identity.
 * Ink is relative to the image outer top-left; used metrics remain relative to its unshifted baseline. */
internal interface NativeFloatInlineImage : NativeAtomicInlineMetrics, NativeReplacementPaintBounds {
    val nativeImageId: Int
    val nativeImageSourceOffset: Int
    val nativeImageWidth: Float
    val nativeImageHeight: Float
    val nativeImageInkBounds: NativeFloatBounds
    val nativeImageOccurrence: NativeImageOccurrencePlacement?
    fun drawNativeImage(canvas: Canvas, outer: RectF)
}

internal fun nativeHasPositionedInlineImages(source: Spanned): Boolean =
    source.getSpans(0, source.length, NativeFloatInlineImage::class.java).any {
        it.nativeImageOccurrence != null
    }

/** Reader-owned legacy callbacks whose exact range also carries immutable Min/Gap metrics.
 * Float rows consume those metrics once; arbitrary Layout callbacks do not gain authority. */
internal interface NativeFloatRowMetricEffect
