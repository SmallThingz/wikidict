package app.smallthingz.dict

import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** Coordinates stay in the source image-layout plane; density/zoom affect only painted bounds. */
internal data class ImageMapBounds(val left: Double, val top: Double, val width: Double, val height: Double)
internal sealed interface ImageMapHit {
    data object Outside : ImageMapHit
    data object None : ImageMapHit
    data object GeometryUnavailable : ImageMapHit
    data class Action(val action: ImageMapAction, val regionIndex: Int?) : ImageMapHit
}
private class UnavailableImageMapGeometry : RuntimeException()
private fun mapFinite(value: Double): Double = value.also {
    if (!it.isFinite()) throw UnavailableImageMapGeometry()
}
private fun mapPositive(value: Double): Boolean = value.isFinite() && value > 0.0

internal class PreparedImageMap private constructor(
    private val map: ImageMap, private val coordinates: List<List<Double>>,
    private val width: Double, private val height: Double,
) {
    fun hit(painted: ImageMapBounds, x: Double, y: Double): ImageMapHit = try {
        if (!painted.left.isFinite() || !painted.top.isFinite() || !mapPositive(painted.width) ||
            !mapPositive(painted.height) || !x.isFinite() || !y.isFinite()) throw UnavailableImageMapGeometry()
        if (x < painted.left || y < painted.top) ImageMapHit.Outside else {
            val dx = mapFinite(x - painted.left)
            val dy = mapFinite(y - painted.top)
            if (dx >= painted.width || dy >= painted.height) ImageMapHit.Outside else {
                val localX = mapFinite((dx / painted.width) * width)
                val localY = mapFinite((dy / painted.height) * height)
                val index = map.regions.indices.firstOrNull { contains(map.regions[it].shape, coordinates[it], localX, localY) }
                if (index != null) ImageMapHit.Action(map.regions[index].action, index)
                else map.defaultAction?.let { ImageMapHit.Action(it, null) } ?: ImageMapHit.None
            }
        }
    } catch (_: UnavailableImageMapGeometry) { ImageMapHit.GeometryUnavailable }

    companion object {
        fun prepare(map: ImageMap, originalWidth: Long, originalHeight: Long,
            layoutWidth: Double, layoutHeight: Double): PreparedImageMap? = try {
            if (originalWidth !in 1L..0xffff_ffffL || originalHeight !in 1L..0xffff_ffffL ||
                !mapPositive(layoutWidth) || !mapPositive(layoutHeight)) throw UnavailableImageMapGeometry()
            val ratio = mapFinite(mapFinite(layoutWidth + layoutHeight) / (originalWidth.toDouble() + originalHeight))
            if (ratio <= 0.0) throw UnavailableImageMapGeometry()
            var remaining = (1 shl 20) - map.regions.size - if (map.defaultAction == null) 0 else 1
            if (remaining < 0) throw UnavailableImageMapGeometry()
            val coordinates = map.regions.map { region ->
                if (region.coordinates.size > remaining) throw UnavailableImageMapGeometry()
                remaining -= region.coordinates.size
                region.coordinates.map { original ->
                    val value = mapFinite(original * ratio)
                    // Kotlin round uses ties-to-even; the compiled map contract uses half-away.
                    mapFinite(Math.copySign(floor(abs(value) + 0.5), value))
                }
            }
            PreparedImageMap(map, coordinates, layoutWidth, layoutHeight)
        } catch (_: UnavailableImageMapGeometry) { null }
    }
}

private fun mapSegment(ax: Double, ay: Double, bx: Double, by: Double, x: Double, y: Double): Boolean {
    if (x < min(ax, bx) || x > max(ax, bx) || y < min(ay, by) || y > max(ay, by)) return false
    val dx = mapFinite(bx - ax)
    val dy = mapFinite(by - ay)
    val px = mapFinite(x - ax)
    val py = mapFinite(y - ay)
    return mapFinite(dx * py) == mapFinite(dy * px)
}
private fun contains(shape: ImageMapShape, c: List<Double>, x: Double, y: Double): Boolean = when (shape) {
    ImageMapShape.Rect -> {
        val left = min(c[0], c[2]); val right = max(c[0], c[2])
        val top = min(c[1], c[3]); val bottom = max(c[1], c[3])
        left != right && top != bottom && x >= left && x <= right && y >= top && y <= bottom
    }
    ImageMapShape.Circle -> {
        if (c[2] <= 0.0) false else {
            val dx = mapFinite(x - c[0]); val dy = mapFinite(y - c[1])
            mapFinite(mapFinite(dx * dx) + mapFinite(dy * dy)) <= mapFinite(c[2] * c[2])
        }
    }
    ImageMapShape.Polygon -> {
        var inside = false
        var px = c[c.size - 2]; var py = c.last()
        var boundary = false
        for (i in c.indices step 2) {
            val cx = c[i]; val cy = c[i + 1]
            if (mapSegment(px, py, cx, cy, x, y)) { boundary = true; break }
            if ((py > y) != (cy > y)) {
                val fraction = mapFinite(mapFinite(y - cy) / mapFinite(py - cy))
                val crossing = mapFinite(cx + mapFinite(fraction * mapFinite(px - cx)))
                if (x < crossing) inside = !inside
            }
            px = cx; py = cy
        }
        boundary || inside
    }
}
