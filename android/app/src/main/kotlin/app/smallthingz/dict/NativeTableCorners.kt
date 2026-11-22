package app.smallthingz.dict

/** Physical circular radii in source order; no per-corner clamp or normalization. */
internal data class NativeCornerRadii(val topLeft: Double, val topRight: Double,
    val bottomRight: Double, val bottomLeft: Double) {
    constructor(topLeft: Float, topRight: Float, bottomRight: Float, bottomLeft: Float) :
        this(topLeft.toDouble(), topRight.toDouble(), bottomRight.toDouble(), bottomLeft.toDouble())
    init {
        require(listOf(topLeft, topRight, bottomRight, bottomLeft).all { it.isFinite() && it >= 0.0 })
    }
    internal val clockwise: List<Double> get() = listOf(topLeft, topRight, bottomRight, bottomLeft)
}

internal fun nativeTableCornerRadii(source: TableCornerRadii, density: Float): NativeCornerRadii {
    if (!density.isFinite() || density <= 0f)
        throw UnsupportedFloatLayout("Table corner density is unavailable")
    fun pixels(value: StyleLength): Double {
        if (value.unit != StyleLengthUnit.Px || !value.value.isFinite() || value.value !in 0f..16777216f)
            throw UnsupportedFloatLayout("Table corner length is unavailable")
        val result = value.value.toDouble() * density.toDouble()
        if (!result.isFinite())
            throw UnsupportedFloatLayout("Table corner length exceeds native geometry")
        return result
    }
    return NativeCornerRadii(pixels(source.topLeft), pixels(source.topRight),
        pixels(source.bottomRight), pixels(source.bottomLeft))
}

/** One normalization at the actual border box. The inner corners are never renormalized. */
internal class NativeTableCornerShape {
    val borderBox: NativeFloatBounds
    val borderWidth: Float
    val outerRadii: NativeCornerRadii
    val paddingBox: NativeFloatBounds?
    val innerRadii: NativeCornerRadii

    constructor(borderBox: NativeFloatBounds, corners: NativeCornerRadii, borderWidth: Float) {
        this.borderBox = borderBox
        this.borderWidth = borderWidth
        if (!borderWidth.isFinite() || borderWidth < 0f)
            throw UnsupportedFloatLayout("Table corner border is unavailable")
        val width = borderBox.right.toDouble() - borderBox.left
        val height = borderBox.bottom.toDouble() - borderBox.top
        if (!width.isFinite() || !height.isFinite() || width < 0.0 || height < 0.0 ||
            width > Float.MAX_VALUE || height > Float.MAX_VALUE)
            throw UnsupportedFloatLayout("Table corner owner bounds are unavailable")
        val radii = corners.clockwise
        var factor = 1.0
        for ((available, sum) in listOf(width to (radii[0] + radii[1]),
            width to (radii[3] + radii[2]), height to (radii[0] + radii[3]),
            height to (radii[1] + radii[2]))) {
            if (sum > 0.0) factor = minOf(factor, available / sum)
        }
        val outer = radii.map { it * factor }
        outerRadii = NativeCornerRadii(outer[0], outer[1], outer[2], outer[3])
        val inner = outer.map { (it - borderWidth).coerceAtLeast(0.0) }
        innerRadii = NativeCornerRadii(inner[0], inner[1], inner[2], inner[3])
        paddingBox = if (width <= 2.0 * borderWidth || height <= 2.0 * borderWidth) null else
            NativeFloatBounds(borderBox.left + borderWidth, borderBox.top + borderWidth,
                borderBox.right - borderWidth, borderBox.bottom - borderWidth)
    }

    private constructor(borderBox: NativeFloatBounds, borderWidth: Float,
        outerRadii: NativeCornerRadii, paddingBox: NativeFloatBounds?, innerRadii: NativeCornerRadii) {
        this.borderBox = borderBox
        this.borderWidth = borderWidth
        this.outerRadii = outerRadii
        this.paddingBox = paddingBox
        this.innerRadii = innerRadii
    }

    /** Coordinate projection preserves the already normalized corners exactly. */
    fun translated(dx: Float, dy: Float): NativeTableCornerShape {
        fun move(box: NativeFloatBounds): NativeFloatBounds {
            val values = listOf(box.left + dx, box.top + dy, box.right + dx, box.bottom + dy)
            if (values.any { !it.isFinite() })
                throw UnsupportedFloatLayout("Table corner translation is unavailable")
            return NativeFloatBounds(values[0], values[1], values[2], values[3])
        }
        return NativeTableCornerShape(move(borderBox), borderWidth, outerRadii, paddingBox?.let(::move), innerRadii)
    }

    /** Centers stay at the outer corners when the positive inner radius is reduced by b. */
    internal fun center(index: Int): Pair<Double, Double> {
        val radius = outerRadii.clockwise[index]
        return (if (index == 0 || index == 3) borderBox.left + radius else borderBox.right - radius) to
            (if (index < 2) borderBox.top + radius else borderBox.bottom - radius)
    }

    /** Half-open rectangular bounds match native hit testing; circular edges are inclusive. */
    fun contains(x: Float, y: Float, padding: Boolean = false): Boolean {
        if (!x.isFinite() || !y.isFinite()) return false
        val box = (if (padding) paddingBox else borderBox) ?: return false
        if (x < box.left || x >= box.right || y < box.top || y >= box.bottom) return false
        val radii = (if (padding) innerRadii else outerRadii).clockwise
        return radii.indices.all { index ->
            val radius = radii[index]
            if (radius == 0.0) true else {
                val (cx, cy) = center(index)
                val inwardX = if (index == 0 || index == 3) x >= cx else x <= cx
                val inwardY = if (index < 2) y >= cy else y <= cy
                val dx = x.toDouble() - cx
                val dy = y.toDouble() - cy
                inwardX || inwardY || dx * dx + dy * dy <= radius * radius
            }
        }
    }
}
