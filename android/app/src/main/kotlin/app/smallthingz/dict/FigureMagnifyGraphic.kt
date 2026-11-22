package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path

/** Source-compiled paths from MediaWiki's retained 305-byte magnify-clip SVGs.
 * LTR SHA256 78f5ef3e585b3073c58b955ace7c662e51ee29bb2ff4ef4b0769bc46e8d7110c
 * RTL SHA256 d4325f0834c822c64efacd2b1ec096331587a6ecba5913776cbf5c600b83747f */
internal data class FigureMagnifyRectangle(val startX: Float, val top: Float, val endX: Float, val bottom: Float)

internal fun figureMagnifyRectangles(graphic: FigureMediaGraphic): List<FigureMagnifyRectangle> = when (graphic) {
    FigureMediaGraphic.MagnifyClipLtrV1 -> listOf(
        FigureMagnifyRectangle(1.509f, 1.865f, 12.499f, 9.784f),
        FigureMagnifyRectangle(-1.499f, 6.868f, 4.444f, 11.772f))
    FigureMediaGraphic.MagnifyClipRtlV1 -> listOf(
        FigureMagnifyRectangle(9.491f, 1.865f, -1.499f, 9.784f),
        FigureMagnifyRectangle(12.499f, 6.868f, 6.556f, 11.772f))
}

private val figureMagnifyPaths by lazy {
    FigureMediaGraphic.entries.associateWith { graphic ->
        figureMagnifyRectangles(graphic).map { box -> Path().apply {
            moveTo(box.startX, box.top); lineTo(box.endX, box.top)
            lineTo(box.endX, box.bottom); lineTo(box.startX, box.bottom); close()
        } }
    }
}

/** The SVG viewport clips the artwork, including the paths outside its viewBox. */
internal fun paintFigureMagnifyGraphic(canvas: Canvas, left: Float, top: Float, density: Float,
    value: FigureGraphicPaint) {
    require(left.isFinite() && top.isFinite() && density.isFinite() && density > 0f)
    val saved = canvas.save()
    canvas.translate(left, top)
    canvas.scale(density, density)
    canvas.clipRect(0f, 0f, 15f, 11f)
    canvas.translate(52f / 15f, 0f)
    canvas.scale(11f / 15f, 11f / 15f)
    val brush = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        strokeWidth = 1f; strokeJoin = Paint.Join.MITER; strokeMiter = 4f; strokeCap = Paint.Cap.BUTT
    }
    for (path in figureMagnifyPaths.getValue(value.graphic)) {
        brush.style = Paint.Style.FILL; brush.color = if (value.invert) Color.BLACK else Color.WHITE
        canvas.drawPath(path, brush)
        brush.style = Paint.Style.STROKE; brush.color = if (value.invert) Color.WHITE else Color.BLACK
        canvas.drawPath(path, brush)
    }
    canvas.restoreToCount(saved)
}
