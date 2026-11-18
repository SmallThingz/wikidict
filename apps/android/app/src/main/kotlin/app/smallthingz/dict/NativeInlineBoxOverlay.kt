package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.RectF
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.SpannedString
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import kotlin.math.floor

/** One detached source occurrence. Its text never enters the containing measured paragraph. */
internal class NativeInlineBoxOverlaySource(
    val index: Int,
    source: Spanned,
    paint: TextPaint,
    val lineHeight: NativeLineHeightPolicy,
    val alignment: InlineBoxOverlayTextAlign,
    val rtl: Boolean,
) {
    val paint = TextPaint(paint)
    val source: Spanned = SpannedString(SpannableString(source.toString()).apply {
        // Retain the original leaf paints. Paragraph policies and ancestor struts
        // belong to the normal-flow owner, never this independent text layout.
        source.getSpans(0, source.length, android.text.style.CharacterStyle::class.java).forEach { span ->
            setSpan(nativeInlineStyleSpanCopy(span), source.getSpanStart(span), source.getSpanEnd(span), source.getSpanFlags(span))
        }
        setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(paint), lineHeight,
            strut = true, includePrimaryInNormal = true, independentNormalStrut = true),
            0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    })
    init {
        require(index >= 0 && source.isNotEmpty())
        require(paint.baselineShift == 0)
        if (source.any { it == '\n' || it == '\r' || it == '\t' || it == '\ufffc' ||
                android.icu.lang.UCharacter.hasBinaryProperty(it.code, android.icu.lang.UProperty.BIDI_CONTROL) })
            throw UnsupportedFloatLayout("Positioned inline text contains unsupported native controls")
    }
}

/** Content dimensions are independent of its real text line bands. Opposite insets can
 * make the used height smaller than the text; visible overflow remains selectable. */
internal data class NativeInlineBoxOverlayPlacement(val border: NativeFloatBounds,
    val contentLeft: Float, val contentTop: Float, val contentWidth: Float, val contentHeight: Float)

/** Measured LTR inline policy: first/last padding edges, with crossed inline edges
 * clamped at the first start. This is not the union of intervening fragments. */
internal fun nativeInlineBoxOverlayLtrContainingPadding(first: NativeFloatBounds,
    last: NativeFloatBounds): NativeFloatBounds {
    nativeInlineBoxCoordinates(first.left, first.top, first.right, first.bottom,
        last.left, last.top, last.right, last.bottom)
    require(first.right >= first.left && first.bottom >= first.top &&
        last.right >= last.left && last.bottom >= last.top)
    if (last.bottom < first.top) throw UnsupportedFloatLayout("Inline overlay has reversed block edges")
    return NativeFloatBounds(first.left, first.top, maxOf(first.left, last.right), last.bottom)
}

internal fun nativeInlineBoxOverlayPlacement(overlay: NativeInlineBoxOverlay, containing: NativeFloatBounds,
    rtl: Boolean, minimum: Float, preferred: Float, naturalHeight: (Float) -> Float): NativeInlineBoxOverlayPlacement {
    nativeInlineBoxCoordinates(containing.left, containing.top, containing.right, containing.bottom, minimum, preferred)
    require(containing.right >= containing.left && containing.bottom >= containing.top && minimum >= 0f && preferred >= minimum)
    val inset = overlay.insets
    val border = overlay.border
    val left = inset.left?.resolve(containing.right - containing.left)
    val right = inset.right?.resolve(containing.right - containing.left)
    val horizontal = border.left.width.toDouble() + border.right.width
    val available = maxOf(0.0, containing.right.toDouble() - containing.left - (left ?: 0f) - (right ?: 0f) - horizontal)
    // With both horizontal insets definite, auto width solves the equation. With
    // one auto inset, use the genuine native preferred/min-content widths.
    val contentWidth = nativeInlineBoxCoordinate(if (left != null && right != null) available
        else minOf(maxOf(minimum.toDouble(), available), preferred.toDouble()))
    val outerWidth = contentWidth.toDouble() + horizontal
    val x = if (left == null || right != null && rtl && outerWidth > containing.right.toDouble() - containing.left - left - right)
        containing.right.toDouble() - checkNotNull(right) - outerWidth
        else containing.left.toDouble() + left
    val top = inset.top?.resolve(containing.bottom - containing.top)
    val bottom = inset.bottom?.resolve(containing.bottom - containing.top)
    val vertical = border.top.width.toDouble() + border.bottom.width
    val contentHeight = if (top != null && bottom != null)
        nativeInlineBoxCoordinate(maxOf(0.0, containing.bottom.toDouble() - containing.top - top - bottom - vertical))
        else naturalHeight(contentWidth).also { nativeInlineBoxCoordinates(it); require(it >= 0f) }
    val outerHeight = contentHeight.toDouble() + vertical
    val y = if (top == null) containing.bottom.toDouble() - checkNotNull(bottom) - outerHeight
        else containing.top.toDouble() + top
    return NativeInlineBoxOverlayPlacement(NativeFloatBounds(nativeInlineBoxCoordinate(x), nativeInlineBoxCoordinate(y),
        nativeInlineBoxCoordinate(x + outerWidth), nativeInlineBoxCoordinate(y + outerHeight)),
        nativeInlineBoxCoordinate(x + border.left.width), nativeInlineBoxCoordinate(y + border.top.width),
        contentWidth, contentHeight)
}

internal class NativeInlineBoxOverlayGeometry(val source: NativeInlineBoxOverlaySource,
    overlay: NativeInlineBoxOverlay, containing: RectF, val line: Int) {
    private val direction = if (source.rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR
    private val widths = nativeFloatRowIntrinsicWidths(source.source, source.paint, direction, breakWordMinimum = false)
    private fun shape(width: Float): NativeFloatGeometry {
        val alignment = when (source.alignment) {
            InlineBoxOverlayTextAlign.Start -> Layout.Alignment.ALIGN_NORMAL
            InlineBoxOverlayTextAlign.Left -> if (source.rtl) Layout.Alignment.ALIGN_OPPOSITE else Layout.Alignment.ALIGN_NORMAL
            InlineBoxOverlayTextAlign.Right -> if (source.rtl) Layout.Alignment.ALIGN_NORMAL else Layout.Alignment.ALIGN_OPPOSITE
            InlineBoxOverlayTextAlign.Center -> Layout.Alignment.ALIGN_CENTER
        }
        return NativeFloatGeometry.build(source.source, source.paint, floor(width).toInt(), emptyList(),
            alignment = alignment, textDirection = direction, includeFontPadding = false,
            exactAvailableWidth = width)
    }
    private var measured: NativeFloatGeometry? = null
    val placement = nativeInlineBoxOverlayPlacement(overlay, NativeFloatBounds(containing.left, containing.top,
        containing.right, containing.bottom), source.rtl, widths.minimum, widths.maximum) { width ->
        shape(width).also { measured = it }.textBottom
    }
    val geometry: NativeFloatGeometry = measured ?: shape(placement.contentWidth)
    val x: Float get() = placement.contentLeft
    val y: Float get() = placement.contentTop
    val paintBounds: List<NativeFloatBounds> get() = geometry.ordinaryPaintBounds.map { it.translated(x, y) }
    val scrollableBounds: NativeFloatBounds get() = geometry.scrollableBounds.translated(x, y)
    fun paint(canvas: Canvas) {
        val save = canvas.save()
        try { canvas.translate(x, y); geometry.paint(canvas) } finally { canvas.restoreToCount(save) }
    }
}
