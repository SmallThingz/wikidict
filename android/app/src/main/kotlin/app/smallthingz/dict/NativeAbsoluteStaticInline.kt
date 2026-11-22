package app.smallthingz.dict

import android.graphics.RectF
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.AlignmentSpan
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** Source custody is the immediate sole RelativeAuto parent, never a numeric zero offset. */
internal data class NativeAbsoluteStaticPosition(val containingBlockId: Int)

/** Captured before the absolute child's formatting context is entered. */
internal data class NativeStaticInlineParent(val format: NativeContainerTextFormat,
    val direction: BidiResolvedDirection, val alignment: Layout.Alignment)

/** The independently resolved parent strut; child source paints and metrics remain unchanged. */
internal data class NativeStaticInlineText(val paint: TextPaint, val lineHeight: NativeLineHeightPolicy,
    val direction: BidiResolvedDirection, val alignment: Layout.Alignment)

internal data class NativeAbsoluteStaticLayout(val left: Float, val top: Float, val width: Float)

/** This private measurement never exports a line, node, action or source character. */
internal fun nativeAbsoluteStaticLayout(child: NativePreparedText, containingWidth: Float,
    carried: List<NativeFloatExclusion>): NativeAbsoluteStaticLayout {
    if (!containingWidth.isFinite() || containingWidth < 0f || containingWidth > TablePixelLimit)
        throw UnsupportedFloatLayout("Static inline containing width exceeds native geometry")
    val parent = child.staticInline
        ?: throw UnsupportedFloatLayout("Static inline parent formatting is unavailable")
    val source = child.source(floor(containingWidth).toInt())
    if (source.isEmpty() || source.any { it.code < 0x20 || it.code == 0x7f })
        throw UnsupportedFloatLayout("Static inline positioning requires its complete ordinary source paragraph")
    val declaring = NativePrimaryFontMetrics.from(child.paint)
    if (declaring.baselineShift != 0f || parent.paint.baselineShift != 0)
        throw UnsupportedFloatLayout("Static inline positioning requires baseline-aligned declaring fonts")
    val hypothetical = SpannableString(source)
    hypothetical.getSpans(0, source.length, AlignmentSpan::class.java).forEach { alignment ->
        if (hypothetical.getSpanStart(alignment) != 0 || hypothetical.getSpanEnd(alignment) != source.length ||
                alignment.javaClass != AlignmentSpan.Standard::class.java)
            throw UnsupportedFloatLayout("Static inline paragraph alignment has an unsupported nested owner")
        hypothetical.removeSpan(alignment)
    }
    hypothetical.setSpan(AlignmentSpan.Standard(parent.alignment), 0, source.length,
        Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    // This strut belongs to the authenticated, unpainted containing paragraph. Its Normal
    // policy must not borrow the absolute child's fallback envelope in mixed-height lines.
    hypothetical.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(parent.paint), parent.lineHeight,
        strut = true, includePrimaryInNormal = true, independentNormalStrut = true), 0, source.length,
        Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    val rtl = parent.direction == BidiResolvedDirection.Rtl
    val probe = NativeFloatGeometry.build(hypothetical, parent.paint, floor(containingWidth).toInt(), emptyList(),
        alignment = parent.alignment,
        textDirection = if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR,
        carriedExclusions = carried, exactAvailableWidth = containingWidth)
    var first = -1
    var firstBounds: RectF? = null
    for (line in 0 until probe.shapedLineCount) {
        val bounds = probe.nativeRubyLineAdvanceBounds(line) ?: continue
        first = line
        firstBounds = bounds
        break
    }
    val bounds = firstBounds
        ?: throw UnsupportedFloatLayout("Static inline source has no native first fragment")
    val anchor = if (rtl) bounds.right else bounds.left
    val top = probe.nativeRubyLineBaseline(first) + declaring.ascent
    // The static side is solved first. Auto width fits the remaining containing span,
    // which differs from the full width for centered/right-aligned wrapped fragments.
    val widths = nativeFloatRowIntrinsicWidths(source, child.paint, child.direction, child.breakWordMinimum)
    val available = if (rtl) anchor else containingWidth - anchor
    val width = min(max(widths.minimum, available), widths.maximum)
    val left = if (rtl) anchor - width else anchor
    if (listOf(widths.minimum, widths.maximum, anchor, top, width, left, left + width).any {
            !it.isFinite() || abs(it) > TablePixelLimit } || widths.minimum < 0f || widths.maximum < widths.minimum)
        throw UnsupportedFloatLayout("Static inline placement exceeds native geometry")
    return NativeAbsoluteStaticLayout(left, top, width)
}
