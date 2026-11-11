package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF

/**
 * Observe only native TextLine's decoration rectangles. There is no raster or replacement owner
 * on this Canvas. The same Layout facade supplies the original lines, bidi, tabs and indents.
 * All operations in that native path are public and overridable on API28.
 */
internal class NativeDecorationBoundsCanvas : Canvas() {
    private data class Translation(val x: Float, val y: Float)
    private val saved = mutableListOf(Translation(0f, 0f))
    var bounds: NativeFloatBounds? = null
        private set
    override fun save(): Int = saved.size.also { saved += saved.last() }
    override fun getSaveCount(): Int = saved.size
    override fun restore() { check(saved.size > 1); saved.removeAt(saved.lastIndex) }
    override fun restoreToCount(saveCount: Int) {
        check(saveCount in 1..saved.size)
        while (saved.size > saveCount) restore()
    }
    override fun translate(dx: Float, dy: Float) {
        val previous = saved.last()
        saved[saved.lastIndex] = Translation(previous.x + dx, previous.y + dy)
    }
    override fun getClipBounds(bounds: Rect): Boolean {
        // NativeLinePainter selects the exact line explicitly. A logical height of zero or a
        // negative used baseline must not let Layout's visibility query suppress that line.
        val limit = Int.MAX_VALUE / 4
        bounds.set(-limit, -limit, limit, limit)
        return true
    }
    override fun drawRect(left: Float, top: Float, right: Float, bottom: Float, paint: Paint) {
        if (right <= left || bottom <= top) return
        check(paint.style == Paint.Style.FILL) { "TextLine decoration must be a native fill rectangle" }
        val shift = saved.last()
        val values = listOf(left.toDouble() + shift.x, top.toDouble() + shift.y,
            right.toDouble() + shift.x, bottom.toDouble() + shift.y)
        if (values.any { !it.isFinite() || kotlin.math.abs(it) > Int.MAX_VALUE / 4.0 })
            throw UnsupportedFloatLayout("Native decoration exceeds the coordinate range")
        bounds = enclosingBounds(bounds, NativeFloatBounds(values[0].toFloat(), values[1].toFloat(),
            values[2].toFloat(), values[3].toFloat()))
    }
    override fun drawRect(rect: RectF, paint: Paint) = drawRect(rect.left, rect.top, rect.right, rect.bottom, paint)
    override fun drawRect(rect: Rect, paint: Paint) = drawRect(rect.left.toFloat(), rect.top.toFloat(), rect.right.toFloat(), rect.bottom.toFloat(), paint)
    override fun drawTextRun(text: CharArray, index: Int, count: Int, contextIndex: Int,
        contextCount: Int, x: Float, y: Float, isRtl: Boolean, paint: Paint) = Unit
    override fun drawTextRun(text: CharSequence, start: Int, end: Int, contextStart: Int,
        contextEnd: Int, x: Float, y: Float, isRtl: Boolean, paint: Paint) = Unit
    override fun drawText(text: CharArray, index: Int, count: Int, x: Float, y: Float, paint: Paint) = Unit
    override fun drawText(text: String, x: Float, y: Float, paint: Paint) = Unit
    override fun drawText(text: String, start: Int, end: Int, x: Float, y: Float, paint: Paint) = Unit
    override fun drawText(text: CharSequence, start: Int, end: Int, x: Float, y: Float, paint: Paint) = Unit

    private fun unsupported(): Nothing = throw UnsupportedFloatLayout("Native decoration observation received an unowned transform")
    override fun scale(sx: Float, sy: Float) = unsupported()
    override fun rotate(degrees: Float) = unsupported()
    override fun skew(sx: Float, sy: Float) = unsupported()
    override fun concat(matrix: Matrix?) = unsupported()
    override fun setMatrix(matrix: Matrix?) = unsupported()
}
