package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.text.Spanned

/** Resolved once from this declaring owner's native font; raw em never enters fitting. */
internal data class NativeInlineAtomicBoxFormat(
    val allocation: NativeInlineAtomicBoxAllocation,
    val textAlign: InlineBoxOverlayTextAlign,
    val wrap: TextWrap,
    val lineHeight: NativeLineHeightPolicy,
)

/** An owned private token, deliberately not an Android ReplacementSpan. MeasuredText
 * receives its exact Float advance; all public text and queries use the real child. */
internal class NativeInlineAtomicBox(
    val format: NativeRubyGroupFormat,
    sourceStart: Int,
    sourceEnd: Int,
    geometry: NativeFloatGeometry,
    val allocation: NativeInlineAtomicBoxAllocation = checkNotNull(format.box?.atomicLayout).allocation,
) : NativeAtomicInlineMetrics {
    private val box = checkNotNull(format.box)
    private val baseline = nativeInlineAtomicBoxBaseline(allocation,
        geometry.textBaselines?.last ?: throw UnsupportedFloatLayout("Atomic inline box requires a real inner line"))
    val advance: Float get() = allocation.marginWidth
    val metrics: NativeUsedLineMetrics get() = baseline.metrics
    override val nativeUsedMetrics: NativeUsedLineMetrics get() = metrics
    val child = NativeRubyChild(sourceStart, sourceEnd, geometry,
        allocation.contentLeft, allocation.contentTop - baseline.baselineFromMarginTop)
    private fun bounds(left: Float, top: Float, width: Float, height: Float) = NativeFloatBounds(
        left, nativeInlineBoxCoordinate(top.toDouble() - baseline.baselineFromMarginTop),
        nativeInlineBoxCoordinate(left.toDouble() + width),
        nativeInlineBoxCoordinate(top.toDouble() + height - baseline.baselineFromMarginTop))
    val borderBounds = bounds(allocation.borderLeft, allocation.borderTop, allocation.borderWidth, allocation.borderHeight)
    val contentBounds = bounds(allocation.contentLeft, allocation.contentTop, allocation.contentWidth, allocation.contentHeight)
    val paddingBounds = NativeFloatBounds(borderBounds.left + box.border.left.width,
        borderBounds.top + box.border.top.width, borderBounds.right - box.border.right.width,
        borderBounds.bottom - box.border.bottom.width)
    private val borderPaint = NativeInlineBoxBorderPaint(RectF(borderBounds.left, borderBounds.top,
        borderBounds.right, borderBounds.bottom), box.border)
    val paintBounds: NativeFloatBounds? get() {
        var result = geometryInk()
        if (format.paint.bgColor ushr 24 != 0) result = enclosingBounds(result, borderBounds)
        borderPaint.bounds.forEach { result = enclosingBounds(result, it) }
        return result
    }
    private fun geometryInk() = child.geometry.extents.ink?.translated(child.x, child.y)
    fun paint(canvas: Canvas) {
        if (format.paint.bgColor ushr 24 != 0) canvas.drawRect(borderBounds.left, borderBounds.top,
            borderBounds.right, borderBounds.bottom, Paint().apply { color = format.paint.bgColor })
        borderPaint.paint(canvas) { box.color(it, format) }
        val saved = canvas.save()
        try {
            canvas.translate(child.x, child.y)
            child.geometry.paint(canvas)
        } finally { canvas.restoreToCount(saved) }
    }
}

internal fun nativeHasAtomicInlineBoxes(source: Spanned): Boolean =
    source.getSpans(0, source.length, NativeInlineAtomicBox::class.java).isNotEmpty() ||
        source.getSpans(0, source.length, NativeRubyPreparedSource::class.java).any { prepared ->
            prepared.groups.values.any { it.box?.isAtomic == true }
        }
