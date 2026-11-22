package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.text.MeasuredText

/**
 * Observe native TextLine decoration rectangles and exact draw-run text bounds.
 * There is no raster or replacement owner. The same Layout facade supplies the original
 * lines, bidi, tabs and indents; unsupported paint retains conservative text bounds.
 */
internal class NativeDecorationBoundsCanvas(private val observeTextBounds: Boolean = false,
    private val ignoreTransparent: Boolean = false) : Canvas() {
    private data class Translation(val x: Float, val y: Float)
    private val saved = mutableListOf(Translation(0f, 0f))
    var bounds: NativeFloatBounds? = null
        private set
    var textBounds: NativeFloatBounds? = null
        private set
    var textBoundsComplete = observeTextBounds
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
        if (right <= left || bottom <= top || ignoreTransparent && paint.alpha == 0) return
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
        contextCount: Int, x: Float, y: Float, isRtl: Boolean, paint: Paint) {
        if (textBoundsComplete && !(ignoreTransparent && paint.alpha == 0)) observeRun(text.copyOfRange(contextIndex, contextIndex + contextCount),
            index - contextIndex, index - contextIndex + count, x, y, isRtl, paint)
    }
    override fun drawTextRun(text: CharSequence, start: Int, end: Int, contextStart: Int,
        contextEnd: Int, x: Float, y: Float, isRtl: Boolean, paint: Paint) {
        if (textBoundsComplete && !(ignoreTransparent && paint.alpha == 0)) observeRun(CharArray(contextEnd - contextStart) { text[contextStart + it] },
            start - contextStart, end - contextStart, x, y, isRtl, paint)
    }
    // NativeLinePainter's Spanned facade dispatches through TextLine.drawTextRun. An
    // unexpected fast path must retain the old conservative bounds, never lose its ink.
    override fun drawText(text: CharArray, index: Int, count: Int, x: Float, y: Float, paint: Paint) { textBoundsComplete = false }
    override fun drawText(text: String, x: Float, y: Float, paint: Paint) { textBoundsComplete = false }
    override fun drawText(text: String, start: Int, end: Int, x: Float, y: Float, paint: Paint) { textBoundsComplete = false }
    override fun drawText(text: CharSequence, start: Int, end: Int, x: Float, y: Float, paint: Paint) { textBoundsComplete = false }

    private fun observeRun(context: CharArray, start: Int, end: Int, x: Float, y: Float,
        isRtl: Boolean, paint: Paint) {
        if (start == end) return
        if (paint.textAlign != Paint.Align.LEFT || paint.style != Paint.Style.FILL ||
            paint.shadowLayerRadius != 0f || paint.startHyphenEdit != 0 || paint.endHyphenEdit != 0) {
            textBoundsComplete = false; return
        }
        // Canvas and MeasuredText use the same native LayoutSplitter on this exact
        // context/range/direction and resolved Paint. Never substitute paragraph context
        // at a soft wrap, or derive the draw origin from rounded Layout advances.
        val measured = MeasuredText.Builder(context).appendStyleRun(paint, context.size, isRtl).build()
        val rect = Rect()
        measured.getBounds(start, end, rect)
        if (rect.isEmpty) return
        // Native line-edge tracking edits move glyphs by at most two half-spacings.
        // Keep that bounded envelope without depending on private Paint run flags.
        val tracking = kotlin.math.abs(paint.letterSpacing.toDouble() * paint.textSize * paint.textScaleX)
        val shift = saved.last()
        val values = listOf(x.toDouble() + shift.x + rect.left - tracking,
            y.toDouble() + shift.y + rect.top, x.toDouble() + shift.x + rect.right + tracking,
            y.toDouble() + shift.y + rect.bottom)
        if (values.any { !it.isFinite() || kotlin.math.abs(it) > Int.MAX_VALUE / 4.0 })
            throw UnsupportedFloatLayout("Native text run exceeds the coordinate range")
        textBounds = enclosingBounds(textBounds, NativeFloatBounds(values[0].toFloat(), values[1].toFloat(),
            values[2].toFloat(), values[3].toFloat()))
    }

    private fun unsupported(): Nothing = throw UnsupportedFloatLayout("Native decoration observation received an unowned transform")
    override fun scale(sx: Float, sy: Float) = unsupported()
    override fun rotate(degrees: Float) = unsupported()
    override fun skew(sx: Float, sy: Float) = unsupported()
    override fun concat(matrix: Matrix?) = unsupported()
    override fun setMatrix(matrix: Matrix?) = unsupported()
}
