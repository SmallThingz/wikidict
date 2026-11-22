package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF

/** Geometry, shades, paths and precision checks are prepared before drawing. */
internal class NativeTableResolvedBorderPaint(plan: NativeTableResolvedBorderPlan) {
    private sealed interface Operation {
        fun paint(canvas: Canvas)

        class Fill(private val path: Path, color: Int, private val clip: RectF? = null) : Operation {
            private val brush = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.FILL }
            override fun paint(canvas: Canvas) {
                if (clip == null) canvas.drawPath(path, brush) else {
                    val saved = canvas.save()
                    try { canvas.clipRect(clip); canvas.drawPath(path, brush) }
                    finally { canvas.restoreToCount(saved) }
                }
            }
        }

        class Stroke(private val path: Path, private val line: TableBorderSegment,
            private val color: Int) : Operation {
            override fun paint(canvas: Canvas) {
                val saved = canvas.save()
                try { canvas.clipPath(path); paintNativeTableBorder(canvas, line, color) }
                finally { canvas.restoreToCount(saved) }
            }
        }
    }

    private class CellPaint(val left: Float, val top: Float, val operations: List<Operation>)

    private val outer = plan.outer?.flatMap(::prepare)
    private val cells = plan.cells.mapValues { (_, cell) -> CellPaint(cell.left, cell.top, cell.regions.flatMap(::prepare)) }
    private val collapsed = plan.collapsed?.flatMap(::prepare)
    val ownsCollapsed: Boolean get() = collapsed != null

    private fun prepare(region: NativeTableResolvedBorderRegion): List<Operation> {
        require(region.polygon.size >= 3)
        val path = Path().apply {
            moveTo(region.polygon.first().x, region.polygon.first().y)
            region.polygon.drop(1).forEach { lineTo(it.x, it.y) }
            close()
        }
        val bounds = RectF(region.polygon.minOf { it.x }, region.polygon.minOf { it.y },
            region.polygon.maxOf { it.x }, region.polygon.maxOf { it.y })
        val vertical = region.line.x1 == region.line.x2
        fun stamp(line: TableBorderSegment): Operation {
            val center = if (vertical) line.x1 else line.y1
            nativeTableBorderStrokePreflight(center, line.width, region.normalLow, region.normalHigh)
            return Operation.Stroke(path, line, region.argb)
        }
        fun shaded(raised: Boolean): Int {
            val topOrLeft = region.side == NativeTableBorderSide.Top || region.side == NativeTableBorderSide.Left
            return if (raised == topOrLeft) nativeResolvedTableLighter150(region.argb) else region.argb
        }
        return when (region.stroke) {
            TableStroke.None, TableStroke.Hidden -> emptyList()
            TableStroke.Solid -> listOf(Operation.Fill(path, region.argb))
            TableStroke.Dotted -> listOf(stamp(region.line))
            TableStroke.Double -> tableBorderBands(region.line).map(::stamp)
            TableStroke.Inset, TableStroke.Outset -> {
                if (!region.collapsed) listOf(Operation.Fill(path, shaded(region.stroke == TableStroke.Outset)))
                else {
                    // The selected Qt policy splits the already-scaled physical width.
                    // Bottom/right outer halves are the remainder, including zero at w=1.
                    val firstWidth = kotlin.math.floor(region.line.width.toDouble() / 2.0 + 0.5).toFloat()
                    val secondWidth = region.line.width - firstWidth
                    require(firstWidth >= 0f && secondWidth >= 0f)
                    val split = (region.normalLow.toDouble() + firstWidth).toFloat()
                    require((firstWidth == 0f || split > region.normalLow) &&
                        (secondWidth == 0f || split < region.normalHigh)) {
                        "Table border bevel loses a positive physical band"
                    }
                    val outerRaised = region.stroke == TableStroke.Inset // collapsed inset paints ridge
                    val lowIsOuter = region.side == NativeTableBorderSide.Top || region.side == NativeTableBorderSide.Left
                    val firstColor = shaded(if (lowIsOuter) outerRaised else !outerRaised)
                    val secondColor = shaded(if (lowIsOuter) !outerRaised else outerRaised)
                    fun band(low: Float, high: Float, color: Int): Operation = Operation.Fill(path, color,
                        if (vertical) RectF(low, bounds.top, high, bounds.bottom)
                        else RectF(bounds.left, low, bounds.right, high))
                    buildList {
                        if (firstWidth > 0f) add(band(region.normalLow, split, firstColor))
                        if (secondWidth > 0f) add(band(split, region.normalHigh, secondColor))
                    }
                }
            }
        }
    }

    fun paintOuter(canvas: Canvas): Boolean {
        val operations = outer ?: return false
        operations.forEach { it.paint(canvas) }
        return true
    }

    fun paintCollapsed(canvas: Canvas): Boolean {
        val operations = collapsed ?: return false
        operations.forEach { it.paint(canvas) }
        return true
    }

    fun paintCell(canvas: Canvas, index: Int): Boolean {
        val cell = cells[index] ?: return false
        cell.operations.forEach { it.paint(canvas) }
        return true
    }

    /** The existing opacity layer supplies the unchanged cell border-box origin. */
    fun paintCellAt(canvas: Canvas, index: Int, left: Float, top: Float): Boolean {
        val cell = cells[index] ?: return false
        val saved = canvas.save()
        try {
            canvas.translate(left - cell.left, top - cell.top)
            cell.operations.forEach { it.paint(canvas) }
        } finally { canvas.restoreToCount(saved) }
        return true
    }
}
