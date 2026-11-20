package app.smallthingz.dict

/** Selected table-edge paint policy follows QColor::lighter(150): RGB16 -> HSV16,
 * integer value scaling with saturation reduction on overflow, then RGB16 -> RGB8.
 * This derives a used shade; it does not change the authored base color. */
internal fun nativeResolvedTableLighter150(argb: Int): Int {
    fun nearest(value: Float): Int = kotlin.math.floor(value.toDouble() + 0.5).toInt()
    fun channel(value: Int): Int {
        val rounded = value + 128
        return (rounded - (rounded ushr 8)) ushr 8
    }
    val red = ((argb ushr 16) and 255) * 257
    val green = ((argb ushr 8) and 255) * 257
    val blue = (argb and 255) * 257
    val minimum = minOf(red, green, blue)
    val maximum = maxOf(red, green, blue)
    val hue: Int
    var saturation: Int
    if (minimum == maximum) {
        hue = 65535
        saturation = 0
    } else {
        val chroma = (maximum - minimum).toFloat()
        saturation = nearest(chroma / maximum * 65535f)
        val sector = when (maximum) {
            red -> ((green - blue) / chroma).let { if (it < 0f) it + 6f else it }
            green -> 2f + (blue - red) / chroma
            else -> 4f + (red - green) / chroma
        }
        hue = nearest(sector * 6000f)
    }
    var value = (150 * maximum) / 100
    if (value > 65535) {
        saturation = (saturation - (value - 65535)).coerceAtLeast(0)
        value = 65535
    }
    val rgb = if (saturation == 0 || hue == 65535) intArrayOf(value, value, value) else {
        val h = if (hue == 36000) 0f else hue / 6000f
        val s = saturation / 65535f
        val v = value / 65535f
        val sector = h.toInt()
        val fraction = h - sector
        val p = v * (1f - s)
        if ((sector and 1) != 0) {
            val q = v * (1f - s * fraction)
            when (sector) {
                1 -> intArrayOf(nearest(q * 65535f), nearest(v * 65535f), nearest(p * 65535f))
                3 -> intArrayOf(nearest(p * 65535f), nearest(q * 65535f), nearest(v * 65535f))
                5 -> intArrayOf(nearest(v * 65535f), nearest(p * 65535f), nearest(q * 65535f))
                else -> error("Invalid table border hue sector")
            }
        } else {
            val t = v * (1f - s * (1f - fraction))
            when (sector) {
                0 -> intArrayOf(nearest(v * 65535f), nearest(t * 65535f), nearest(p * 65535f))
                2 -> intArrayOf(nearest(p * 65535f), nearest(v * 65535f), nearest(t * 65535f))
                4 -> intArrayOf(nearest(t * 65535f), nearest(p * 65535f), nearest(v * 65535f))
                else -> error("Invalid table border hue sector")
            }
        }
    }
    return (argb and (255 shl 24)) or (channel(rgb[0]) shl 16) or (channel(rgb[1]) shl 8) or channel(rgb[2])
}
