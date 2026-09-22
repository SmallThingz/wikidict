package app.smallthingz.dict

import kotlin.math.expm1
import kotlin.math.ln1p
import kotlin.math.roundToInt

/** log1p includes a real zero for cache-off; endpoints round trip exactly. */
data class SliderScale(val min: Int, val max: Int, val logarithmic: Boolean = false) {
    init { require(min >= 0 && max > min) }
    fun position(value: Int): Float {
        val v = value.coerceIn(min, max).toDouble()
        return if (logarithmic) ((ln1p(v) - ln1p(min.toDouble())) / (ln1p(max.toDouble()) - ln1p(min.toDouble()))).toFloat()
        else ((v - min) / (max - min)).toFloat()
    }
    fun value(position: Float): Int {
        val p = position.coerceIn(0f, 1f).toDouble()
        return (if (logarithmic) expm1(ln1p(min.toDouble()) + p * (ln1p(max.toDouble()) - ln1p(min.toDouble())))
        else min + p * (max - min)).roundToInt().coerceIn(min, max)
    }
}
