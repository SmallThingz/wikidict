package app.smallthingz.dict

/** Resolved physical RT margins. Content, paint and source selection retain their own band. */
internal data class NativeRubyAnnotationMargins(val top: Float, val bottom: Float) {
    init {
        if (!top.isFinite() || !bottom.isFinite() || top < 0f || bottom < 0f ||
            top > TablePixelLimit || bottom > TablePixelLimit)
            throw UnsupportedFloatLayout("Ruby annotation margins exceed native geometry")
    }

    fun reservation(content: NativeUsedLineMetrics): NativeUsedLineMetrics {
        val first = content.top.toDouble() - top
        val last = content.bottom.toDouble() + bottom
        if (!first.isFinite() || !last.isFinite() ||
            kotlin.math.abs(first) > TablePixelLimit || kotlin.math.abs(last) > TablePixelLimit)
            throw UnsupportedFloatLayout("Ruby annotation margin box exceeds native geometry")
        return NativeUsedLineMetrics(first.toFloat(), last.toFloat())
    }
}

internal fun nativeRubyAnnotationMargins(source: RubyAnnotationMargins,
    declaringFontPixels: Float, density: Float): NativeRubyAnnotationMargins {
    if (!declaringFontPixels.isFinite() || declaringFontPixels < 0f || !density.isFinite() || density <= 0f)
        throw UnsupportedFloatLayout("Ruby annotation margin font or density is unavailable")
    fun edge(value: StyleLength): Float {
        val pixels = value.value.toDouble() *
            if (value.unit == StyleLengthUnit.Em) declaringFontPixels else density
        if (!pixels.isFinite() || pixels < 0.0 || pixels > TablePixelLimit)
            throw UnsupportedFloatLayout("Ruby annotation margin exceeds native geometry")
        return pixels.toFloat()
    }
    return NativeRubyAnnotationMargins(edge(source.top), edge(source.bottom))
}
