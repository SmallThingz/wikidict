package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path

/** Source colors and box states are replayed; this is not a claim of browser UA theme equality.
 * Inset/outset currently reuse the reader's selected bevel policy. Black native-button UA
 * bevels and device font identity need independent visual qualification before acceptance. */
internal fun paintNativeDisclosureButton(canvas: Canvas, button: ContainerDisclosureButton,
    state: ContainerDisclosureButtonState, density: Float, width: Float, height: Float) {
    fun color(value: FigureColor): Int = when (value) {
        FigureColor.Transparent -> 0
        is FigureColor.Rgb -> checkNotNull(canonicalColorArgb(value.value)).toInt()
        else -> error("Invalid button color")
    }
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color(state.background) }
    canvas.drawRect(0f, 0f, width, height, paint)
    val edges = state.border.disclosureEdges()
    val widths = edges.map { (it.disclosureLine()?.first?.value ?: 0f) * density }
    val t = widths[0]; val r = widths[1]; val b = widths[2]; val l = widths[3]
    val polygons = listOf(
        floatArrayOf(0f,0f, width,0f, width-r,t, l,t),
        floatArrayOf(width,0f, width,height, width-r,height-b, width-r,t),
        floatArrayOf(width,height, 0f,height, l,height-b, width-r,height-b),
        floatArrayOf(0f,height, 0f,0f, l,t, l,height-b))
    edges.forEachIndexed { side, edge ->
        val line = edge.disclosureLine() ?: return@forEachIndexed
        val thick = widths[side]
        if (thick == 0f) return@forEachIndexed
        val raw = checkNotNull(canonicalColorArgb((line.second as StyleBorderPaint.Rgb).value)).toInt()
        val light = edge is ResolvedStyleBorderEdge.Outset && side in listOf(0,3) ||
            edge is ResolvedStyleBorderEdge.Inset && side in listOf(1,2)
        paint.color = if (light) nativeResolvedTableLighter150(raw) else raw
        paint.style = Paint.Style.FILL
        val points = polygons[side]
        val path = Path().apply {
            moveTo(points[0],points[1])
            for (i in 2 until points.size step 2) lineTo(points[i],points[i+1])
            close()
        }
        if (edge !is ResolvedStyleBorderEdge.Dotted) canvas.drawPath(path,paint) else {
            val saved = canvas.save()
            try {
                canvas.clipPath(path)
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = thick
                paint.strokeCap = Paint.Cap.ROUND
                paint.pathEffect = android.graphics.DashPathEffect(floatArrayOf(0.01f, thick*2f), 0f)
                when (side) {
                    0 -> canvas.drawLine(0f,t/2f,width,t/2f,paint)
                    1 -> canvas.drawLine(width-r/2f,0f,width-r/2f,height,paint)
                    2 -> canvas.drawLine(0f,height-b/2f,width,height-b/2f,paint)
                    3 -> canvas.drawLine(l/2f,0f,l/2f,height,paint)
                }
            } finally { canvas.restoreToCount(saved); paint.pathEffect = null }
        }
    }
}
internal fun paintNativeDisclosureButtonFocus(canvas: Canvas, button: ContainerDisclosureButton,
    density: Float, width: Float, height: Float, focused: Boolean, focusVisible: Boolean) {
    val selected = button.outlineColor(focused, focusVisible)
    val outline = button.focusVisible?.outline?.takeIf { focusVisible } ?: return
    val color = selected as? FigureColor.Rgb ?: return
    val stroke = outline.width.value*density
    val inset = -(outline.offset.value*density + stroke/2f)
    if (width - inset <= inset || height - inset <= inset) return
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        this.color = checkNotNull(canonicalColorArgb(color.value)).toInt()
        style = Paint.Style.STROKE
        strokeWidth = stroke
    }
    canvas.drawRect(inset, inset, width-inset, height-inset, paint)
}
