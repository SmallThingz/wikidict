package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PathMeasure
import android.graphics.RectF
import kotlin.math.abs

internal interface NativeInlineBoxCurvePaint {
    fun contains(x: Float, y: Float): Boolean
    fun paint(canvas: Canvas, background: Int, borderColor: Int)
}

/** The one composite path fixes dot phase. Slice preparation extracts only the
 * center-line intervals that can paint that window, so long wrapped owners do
 * not dash their entire perimeter again for every physical fragment. */
internal class NativeInlineBoxEllipseDecoration(val shape: NativeInlineBoxEllipseShape, val dotted: Boolean) {
    init { nativeInlineBoxEllipseNativePrecision(shape, 0.0, shape.width) }
    private fun finite(value: Double): Float = value.toFloat().also {
        if (!it.isFinite()) throw UnsupportedFloatLayout("Elliptical inline path exceeds native coordinates")
    }
    private val width = finite(shape.width)
    private val height = finite(shape.height)
    private val radiusX = finite(shape.radiusX)
    private val radiusY = finite(shape.radiusY)
    private val borderWidth = shape.borderWidth
    private fun roundPath(inset: Float, rx: Float, ry: Float) = Path().apply {
        val x = if (rx == 0f || ry == 0f) 0f else rx
        val y = if (rx == 0f || ry == 0f) 0f else ry
        addRoundRect(RectF(inset, inset, width - inset, height - inset), x, y, Path.Direction.CW)
    }
    private val outer = roundPath(0f, radiusX, radiusY)
    private val ring = Path(outer).apply {
        fillType = Path.FillType.EVEN_ODD
        if (shape.width > 2.0 * borderWidth && shape.height > 2.0 * borderWidth)
            addPath(roundPath(borderWidth, maxOf(0f, radiusX - borderWidth), maxOf(0f, radiusY - borderWidth)))
    }
    private data class Segment(val measure: PathMeasure, val before: Double, val firstX: Float, val lastX: Float)
    private data class DottedPiece(val path: Path, val phase: Float)
    private val segments: List<Segment>
    private val period = borderWidth * 2f

    init {
        if (dotted && borderWidth > 0f && (!period.isFinite() || period <= 0f))
            throw UnsupportedFloatLayout("Dotted inline curve has no representable period")
        val paths = mutableListOf<Path>()
        if (dotted && borderWidth > 0f) {
            val half = borderWidth / 2f
            if (half <= 0f) throw UnsupportedFloatLayout("Dotted inline curve has no representable center line")
            var rx = maxOf(0f, radiusX - half)
            var ry = maxOf(0f, radiusY - half)
            if (rx == 0f || ry == 0f) { rx = 0f; ry = 0f }
            val l = half; val t = half; val r = width - half; val b = height - half
            fun line(x0: Float, y0: Float, x1: Float, y1: Float) {
                if (x0 != x1 || y0 != y1) paths += Path().apply { moveTo(x0, y0); lineTo(x1, y1) }
            }
            fun arc(box: RectF, start: Float) {
                if (rx > 0f && ry > 0f) paths += Path().apply { arcTo(box, start, 90f, true) }
            }
            line(l + rx, t, r - rx, t)
            arc(RectF(r - 2f * rx, t, r, t + 2f * ry), 270f)
            line(r, t + ry, r, b - ry)
            arc(RectF(r - 2f * rx, b - 2f * ry, r, b), 0f)
            line(r - rx, b, l + rx, b)
            arc(RectF(l, b - 2f * ry, l + 2f * rx, b), 90f)
            line(l, b - ry, l, t + ry)
            arc(RectF(l, t, l + 2f * rx, t + 2f * ry), 180f)
        }
        var distance = 0.0
        segments = paths.mapNotNull { path ->
            val measure = PathMeasure(path, false)
            val length = measure.length
            if (!length.isFinite()) throw UnsupportedFloatLayout("Dotted inline contour length is unavailable")
            if (length <= 0f) return@mapNotNull null
            val position = FloatArray(2)
            if (!measure.getPosTan(0f, position, null)) throw UnsupportedFloatLayout("Dotted inline contour start is unavailable")
            val first = position[0]
            if (!measure.getPosTan(length, position, null)) throw UnsupportedFloatLayout("Dotted inline contour end is unavailable")
            Segment(measure, distance, first, position[0]).also { distance += length }
        }
    }

    /** Each quarter arc is monotone in x; one binary search clips it without
     * changing the original contour's accumulated distance or dot phase. */
    private fun distanceAt(segment: Segment, x: Float): Float {
        val length = segment.measure.length
        if (segment.firstX == segment.lastX) return 0f
        val increasing = segment.lastX > segment.firstX
        if (if (increasing) x <= segment.firstX else x >= segment.firstX) return 0f
        if (if (increasing) x >= segment.lastX else x <= segment.lastX) return length
        var first = 0f
        var last = length
        val point = FloatArray(2)
        repeat(28) {
            val middle = (first.toDouble() + last).div(2.0).toFloat()
            if (middle == first || middle == last) return@repeat
            if (!segment.measure.getPosTan(middle, point, null))
                throw UnsupportedFloatLayout("Dotted inline contour position is unavailable")
            if ((point[0] < x) == increasing) first = middle else last = middle
        }
        return (first.toDouble() + last).div(2.0).toFloat()
    }

    private fun pieces(offset: Double, width: Double): List<DottedPiece> {
        if (!dotted || borderWidth == 0f) return emptyList()
        // Include centers just outside the slice when their circular dot reaches it.
        val left = finite(offset - borderWidth / 2.0)
        val right = finite(offset + width + borderWidth / 2.0)
        val result = mutableListOf<DottedPiece>()
        var path: Path? = null
        var pathStart = 0.0
        var lastDistance = Double.NEGATIVE_INFINITY
        fun finish() {
            path?.let { result += DottedPiece(it, (pathStart % period.toDouble()).toFloat()) }
            path = null
        }
        for (segment in segments) {
            if (maxOf(segment.firstX, segment.lastX) < left || minOf(segment.firstX, segment.lastX) > right) {
                finish(); continue
            }
            val vertical = segment.firstX == segment.lastX
            val a = if (vertical) 0f else distanceAt(segment, if (segment.firstX < segment.lastX) left else right)
            val b = if (vertical) segment.measure.length else distanceAt(segment, if (segment.firstX < segment.lastX) right else left)
            if (b <= a) { finish(); continue }
            val at = segment.before + a
            if (path != null && abs(lastDistance - at) > 0.00001) finish()
            val fresh = path == null
            if (fresh) { path = Path(); pathStart = at }
            if (!segment.measure.getSegment(a, b, checkNotNull(path), fresh))
                throw UnsupportedFloatLayout("Dotted inline contour slice is unavailable")
            lastDistance = segment.before + b
            if (b < segment.measure.length) finish()
        }
        finish()
        return result
    }

    fun slice(value: NativeInlineBoxEllipseSlice): NativeInlineBoxCurvePaint {
        require(value.shape == shape)
        nativeInlineBoxEllipseNativePrecision(shape, value.offset, value.fragment.right.toDouble() - value.fragment.left)
        val dottedPieces = pieces(value.offset, value.fragment.right.toDouble() - value.fragment.left)
        val fill = Paint(Paint.ANTI_ALIAS_FLAG)
        val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = borderWidth; strokeCap = Paint.Cap.ROUND
        }
        val paints = dottedPieces.map { piece -> Paint(stroke).apply {
            pathEffect = DashPathEffect(floatArrayOf(0f, period), piece.phase)
        } }
        return object : NativeInlineBoxCurvePaint {
            override fun contains(x: Float, y: Float) = value.contains(x, y)
            override fun paint(canvas: Canvas, background: Int, borderColor: Int) {
                val box = value.fragment
                val checkpoint = canvas.save()
                try {
                    canvas.clipRect(box.left, box.top, box.right, box.bottom)
                    canvas.translate(finite(box.left.toDouble() - value.offset), box.top)
                    if (background ushr 24 != 0) { fill.color = background; canvas.drawPath(outer, fill) }
                    if (borderWidth > 0f && borderColor ushr 24 != 0) {
                        if (!dotted) { fill.color = borderColor; canvas.drawPath(ring, fill) }
                        else {
                            canvas.clipPath(ring)
                            dottedPieces.forEachIndexed { index, piece ->
                                paints[index].color = borderColor
                                canvas.drawPath(piece.path, paints[index])
                            }
                        }
                    }
                } finally { canvas.restoreToCount(checkpoint) }
            }
        }
    }
}
