package app.smallthingz.dict

import android.graphics.RectF
import android.text.SpannableString
import android.text.Spanned
import android.text.SpannedString
import android.text.TextPaint
import android.text.style.MetricAffectingSpan
import kotlin.math.abs

/** One original in-flow owner. Decoration does not create an action occurrence. */
internal class NativeInlineBoxOwner(val span: Span, val path: String)

internal data class NativeInlineBoxEdges(val top: Float, val right: Float, val bottom: Float, val left: Float) {
    init { nativeInlineBoxCoordinates(top, right, bottom, left); require(listOf(top, right, bottom, left).all { it >= 0f }) }
}

/** A null color means the declaring owner's current color, including its actual action state. */
internal data class NativeInlineBoxBorder(val width: Float, val color: Int?, val dotted: Boolean = false) {
    init { nativeInlineBoxCoordinates(width); require(width >= 0f) }
}
internal data class NativeInlineBoxBorders(val top: NativeInlineBoxBorder, val right: NativeInlineBoxBorder,
    val bottom: NativeInlineBoxBorder, val left: NativeInlineBoxBorder)

/** Px/em insets are resolved once; percentages retain their containing-axis basis until placement. */
internal data class NativeInlineBoxInset(val value: Float, val percentage: Boolean) {
    init { require(value.isFinite()) }
    fun resolve(basis: Float): Float = nativeInlineBoxCoordinate(if (percentage)
        basis.toDouble() * value / 100.0 else value.toDouble())
}
internal data class NativeInlineBoxInsets(val top: NativeInlineBoxInset?, val right: NativeInlineBoxInset?,
    val bottom: NativeInlineBoxInset?, val left: NativeInlineBoxInset?) {
    init { require((top != null || bottom != null) && (left != null || right != null)) }
}
internal data class NativeInlineBoxOverlay(val insets: NativeInlineBoxInsets, val border: NativeInlineBoxBorders)

internal class NativeInlineBoxFormat(val owner: NativeInlineBoxOwner, val padding: NativeInlineBoxEdges,
    val border: NativeInlineBoxBorders, overlays: List<NativeInlineBoxOverlay>,
    val currentColorPaint: NativeMissingLinkPaint? = null, val radius: Float? = null,
    val atomicLayout: NativeInlineAtomicBoxFormat? = null, val radiusPercentage: Boolean = false,
    val atomicAutoLayout: NativeInlineAtomicAutoBoxFormat? = null,
    val intrinsicLinesLayout: NativeInlineIntrinsicLinesFormat? = null) {
    val isAtomic: Boolean get() = atomicLayout != null || atomicAutoLayout != null || intrinsicLinesLayout != null
    val overlays = overlays.toList()
    val leftAdvance = nativeInlineBoxCoordinate(padding.left.toDouble() + border.left.width)
    val rightAdvance = nativeInlineBoxCoordinate(padding.right.toDouble() + border.right.width)
    init {
        nativeInlineBoxCoordinate(leftAdvance.toDouble() + rightAdvance)
        require(!radiusPercentage || radius != null)
        require(listOf(atomicLayout != null, atomicAutoLayout != null, intrinsicLinesLayout != null).count { it } <= 1)
        if (intrinsicLinesLayout != null && (overlays.isNotEmpty() || radius != null ||
                listOf(padding.top, padding.right, padding.bottom, padding.left,
                    border.top.width, border.right.width, border.bottom.width, border.left.width).any { it != 0f }))
            throw UnsupportedFloatLayout("Intrinsic line owner requires its undecorated content box")
        radius?.let { value ->
            if (!value.isFinite()) throw UnsupportedFloatLayout("Rounded inline radius is unavailable")
            if (!radiusPercentage) nativeInlineBoxCoordinates(value)
            val first = border.top
            if (value < 0f || overlays.isNotEmpty() || isAtomic || first.color == null || first.color ushr 24 != 255 ||
                listOf(border.top, border.right, border.bottom, border.left).any {
                    it.dotted != first.dotted || it.width != first.width || it.color != first.color
                }) throw UnsupportedFloatLayout("Rounded inline box requires equal solid or dotted RGB borders without overlays")
        }
    }
    fun color(value: NativeInlineBoxBorder, declaring: NativeRubyGroupFormat): Int = value.color
        ?: currentColorPaint?.appearance()?.color ?: declaring.paint.color
}

/** Installed over only this owner's private native child interval, without inserted characters.
 * Null parentRtl uses the actual paragraph line; an enclosing directional group supplies its flow. */
internal class NativeInlineBoxSpan(val format: NativeRubyGroupFormat, val shift: Float,
    val parentRtl: Boolean?, val overlaySources: List<NativeInlineBoxOverlaySource> = emptyList()) {
    init { require(format.box != null); nativeInlineBoxCoordinates(shift) }
    val box: NativeInlineBoxFormat get() = checkNotNull(format.box)
}

/** A real nonempty metric-run boundary, without any font mutation or source character.
 * Android's measured paragraph and TextLine own the resulting bounded shaping contexts;
 * the run capture still verifies their actual glyphs and advances before publication. */
internal class NativeInlineBoxBoundarySpan : MetricAffectingSpan(), NativeInlineSafePaintSpan {
    override fun updateMeasureState(paint: TextPaint) = Unit
    override fun updateDrawState(paint: TextPaint) = Unit
}

internal fun nativeInlineBoxParagraphRtl(source: CharSequence,
    direction: android.text.TextDirectionHeuristic, offset: Int): Boolean {
    require(offset in source.indices)
    val value = source.toString()
    val first = value.lastIndexOf('\n', offset - 1).let { it + 1 }
    val last = value.indexOf('\n', offset).let { if (it < 0) value.length else it }
    return direction.isRtl(source, first, last - first)
}

internal fun nativeInlineBoxRequiredBreaks(source: Spanned, parentRtl: (Int) -> Boolean): Set<Int> = buildSet {
    nativeInlineRanges(source, NativeInlineBoxSpan::class.java).forEach { range ->
        val box = range.value.box
        val rtl = range.value.parentRtl ?: parentRtl(range.start)
        if ((if (rtl) box.rightAdvance else box.leftAdvance) > 0f) add(range.start)
        if ((if (rtl) box.leftAdvance else box.rightAdvance) > 0f) add(range.end)
    }
}

internal fun nativeInlineBoxBoundedSource(source: Spanned, parentRtl: (Int) -> Boolean): Spanned {
    val breaks = nativeInlineBoxRequiredBreaks(source, parentRtl)
    if (breaks.isEmpty()) return source
    val target = SpannableString(source)
    target.getSpans(0, target.length, NativeInlineBoxBoundarySpan::class.java).forEach(target::removeSpan)
    val ends = (listOf(0, target.length) + breaks).distinct().sorted()
    ends.zipWithNext().forEach { (first, last) ->
        if (first < last) target.setSpan(NativeInlineBoxBoundarySpan(), first, last, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }
    return SpannedString(target)
}

internal fun nativeInlineBoxCoordinate(value: Double): Float {
    if (!value.isFinite() || abs(value) > TablePixelLimit)
        throw UnsupportedFloatLayout("Inline box exceeds native coordinates")
    return value.toFloat()
}
internal fun nativeInlineBoxCoordinates(vararg values: Float) {
    if (values.any { !it.isFinite() || abs(it) > TablePixelLimit })
        throw UnsupportedFloatLayout("Inline box exceeds native coordinates")
}

/** The empty absolute overlay has zero intrinsic content, no margin/padding, and real border widths.
 * Each axis is anchored. Over-constrained zero-content width follows containing direction;
 * vertical auto sizing retains the top constraint. No inline advance or line metric is created. */
internal fun nativeInlineBoxOverlayRect(overlay: NativeInlineBoxOverlay, containing: RectF, rtl: Boolean): RectF {
    nativeInlineBoxCoordinates(containing.left, containing.top, containing.right, containing.bottom)
    require(containing.width() >= 0f && containing.height() >= 0f)
    fun axis(origin: Float, length: Float, first: NativeInlineBoxInset?, last: NativeInlineBoxInset?,
        firstBorder: Float, lastBorder: Float, preferEnd: Boolean): Pair<Float, Float> {
        val start = first?.resolve(length)?.toDouble()
        val end = last?.resolve(length)?.toDouble()
        val minimum = firstBorder.toDouble() + lastBorder
        val available = if (start != null && end != null) length.toDouble() - start - end else minimum
        val extent = maxOf(minimum, available)
        val begin = when {
            start == null -> origin.toDouble() + length - checkNotNull(end) - extent
            end != null && preferEnd && extent > available -> origin.toDouble() + length - end - extent
            else -> origin.toDouble() + start
        }
        return nativeInlineBoxCoordinate(begin) to nativeInlineBoxCoordinate(begin + extent)
    }
    val x = axis(containing.left, containing.width(), overlay.insets.left, overlay.insets.right,
        overlay.border.left.width, overlay.border.right.width, rtl)
    val y = axis(containing.top, containing.height(), overlay.insets.top, overlay.insets.bottom,
        overlay.border.top.width, overlay.border.bottom.width, false)
    return RectF(x.first, y.first, x.second, y.second)
}

/** Realized metrics and original path ownership are shared by the two admitted shapes. */
private fun nativeInlineBoxNestedContext(parent: NativeInlineBoxSpan, child: NativeInlineBoxSpan): Boolean {
    val x = parent.format
    val y = child.format
    fun plain(f: NativeRubyGroupFormat) = f.actionOwner == null && f.actionPaint == null &&
        f.sourceDirection.isEmpty() && f.wrap == null && f.underline == null && f.cursor == null &&
        f.baselineShift == 0f && (f.localBaselineShift == null || f.localBaselineShift == 0f) &&
        f.paint.bgColor == 0 && !f.paint.isUnderlineText && !f.paint.isStrikeThruText &&
        f.box?.owner?.span?.kind == "text"
    return plain(x) && plain(y) && parent.shift == 0f && child.shift == 0f &&
        x.paint.equalsForTextMeasurement(y.paint) && x.lineHeight == y.lineHeight &&
        child.box.owner.path.startsWith(parent.box.owner.path + "/") &&
        !parent.box.isAtomic && !child.box.isAtomic
}

/** The earlier top stroke and its one strict-interior circle retain their original domain. */
internal fun nativeInlineBoxNestedPair(parent: NativeInlineBoxSpan, child: NativeInlineBoxSpan): Boolean {
    val a = parent.box
    val b = child.box
    fun zero(e: NativeInlineBoxEdges) = e.top == 0f && e.right == 0f && e.bottom == 0f && e.left == 0f
    return nativeInlineBoxNestedContext(parent, child) && a.overlays.isEmpty() && b.overlays.isEmpty() &&
        zero(a.padding) && zero(b.padding) && a.radius == null &&
        a.border.top.width > 0f && !a.border.top.dotted &&
        a.border.left.width == 0f && a.border.right.width == 0f && a.border.bottom.width == 0f &&
        b.radiusPercentage && b.radius == 50f && b.border.top.width > 0f && b.border.top.dotted &&
        listOf(b.border.right, b.border.bottom, b.border.left).all { it == b.border.top }
}

internal fun nativeInlineBoxPitchPair(parent: NativeInlineBoxSpan, child: NativeInlineBoxSpan): Boolean {
    if (!nativeInlineBoxNestedContext(parent, child) ||
        nativeInlineBoxPitchChildren(parent.box.owner.span)?.any { it === child.box.owner.span } != true)
        return false
    val a = parent.box
    val b = child.box
    val width = a.border.top.width
    fun edges(value: NativeInlineBoxEdges, amount: Float) = value.top == amount && value.right == amount &&
        value.bottom == amount && value.left == amount
    fun none(value: NativeInlineBoxBorder) = value.width == 0f
    fun stroke(value: NativeInlineBoxBorder) = value.width == width && value.color == null && !value.dotted
    val overlay = a.overlays.singleOrNull() ?: return false
    return width > 0f && edges(a.padding, width) && a.radius == null && stroke(a.border.top) &&
        none(a.border.right) && none(a.border.bottom) && none(a.border.left) &&
        edges(b.padding, 0f) && b.radiusPercentage && b.radius == 50f && b.overlays.isEmpty() &&
        listOf(b.border.top, b.border.right, b.border.bottom, b.border.left).all {
            it.width == width && it.color == 0xff808080.toInt() && it.dotted
        } && parent.overlaySources.isEmpty() && child.overlaySources.isEmpty() &&
        overlay.insets.top == NativeInlineBoxInset(0f, false) &&
        overlay.insets.right == NativeInlineBoxInset(0f, true) &&
        overlay.insets.bottom == NativeInlineBoxInset(67f, true) && overlay.insets.left == null &&
        stroke(overlay.border.right) && none(overlay.border.top) && none(overlay.border.bottom) && none(overlay.border.left)
}

internal fun nativeInlineBoxNesting(spans: List<NativeInlineRange<NativeInlineBoxSpan>>,
    rtl: (NativeInlineRange<NativeInlineBoxSpan>) -> Boolean): List<Int> {
    val pitch = spans.indices.mapNotNull { index ->
        nativeInlineBoxPitchChildren(spans[index].value.box.owner.span)?.let { index to it }
    }.toMap()
    val parents = nativeInlineBoxNestedParents(spans.map { it.start to it.end }, pitch.keys)
        ?: throw UnsupportedFloatLayout("Inline box ranges are outside the selected nested decoration domains")
    parents.forEachIndexed { index, parent ->
        if (parent >= 0 && (!(if (parent in pitch) nativeInlineBoxPitchPair(spans[parent].value, spans[index].value)
                    else nativeInlineBoxNestedPair(spans[parent].value, spans[index].value)) ||
                rtl(spans[parent]) || rtl(spans[index])))
            throw UnsupportedFloatLayout("Nested inline decoration requires its static equal-metric LTR owners")
    }
    val childrenByParent = parents.withIndex().filter { it.value >= 0 }
        .groupBy({ it.value }, { spans[it.index].value.box.owner.span })
    for ((parent, expected) in pitch) {
        val actual = childrenByParent[parent].orEmpty()
        if (actual.size != expected.size || expected.any { source -> actual.count { it === source } != 1 })
            throw UnsupportedFloatLayout("Pitch decoration lost an original child occurrence")
    }
    return parents
}
