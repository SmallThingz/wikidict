package app.smallthingz.dict

import android.graphics.RectF

/** Exact resolved inline-owner font; line-height is supplied independently. */
internal data class FigureMediaFont(val primary: NativePrimaryFontMetrics, val xHeight: Float) {
    init { require(xHeight.isFinite() && xHeight >= 0f) }
}
internal data class FigureMediaLine(val height: Float, val contentTop: Float)

/** Keep the real parent strut and the aligned replaced/inline-block margin box. */
internal fun figureMediaLine(font: FigureMediaFont, alignment: InlineBoxVerticalAlign,
    outerHeight: Float, contentBaseline: Float? = null, lineStrut: NativeUsedLineMetrics? = null): FigureMediaLine {
    require(outerHeight.isFinite() && outerHeight >= 0f)
    val strut = lineStrut ?: checkNotNull(font.primary.authored(NativeLineHeightPolicy.Pixels(0f)))
    val top = when (alignment) {
        // The same native inline-image middle alignment, retaining fractional font metrics.
        InlineBoxVerticalAlign.Middle -> font.primary.baselineShift - (font.xHeight + outerHeight) / 2f
        InlineBoxVerticalAlign.Baseline -> -requireNotNull(contentBaseline).also {
            require(it.isFinite())
        }
        else -> throw UnsupportedFloatLayout("Unsupported Figure anchor alignment")
    }
    val box = strut.including(NativeUsedLineMetrics(top, top + outerHeight))
    return FigureMediaLine(box.height, top - box.top)
}

/** The inline A contributes its font content band; its atomic child contributes its border box.
 * Horizontal margins advance the inline owner. Vertical margins only position the child. */
internal fun figureMissingLinkFragments(labelWidth: Float, labelHeight: Float, lastBaseline: Float,
    border: Float, marginLeft: Float, marginRight: Float,
    font: NativePrimaryFontMetrics): List<NativeFloatBounds> {
    require(listOf(labelWidth,labelHeight,border,marginLeft,marginRight).all { it.isFinite() && it >= 0f })
    require(lastBaseline.isFinite())
    fun bounds(left: Double,top: Double,right: Double,bottom: Double): NativeFloatBounds {
        if(listOf(left,top,right,bottom).any { !it.isFinite() || kotlin.math.abs(it)>TablePixelLimit })
            throw UnsupportedFloatLayout("Missing link fragment exceeds the native geometry range")
        return NativeFloatBounds(left.toFloat(),top.toFloat(),right.toFloat(),bottom.toFloat())
    }
    val baseline=lastBaseline.toDouble()+font.baselineShift
    return listOf(
        bounds(-border.toDouble()-marginLeft,baseline+font.ascent,
            labelWidth.toDouble()+border+marginRight,baseline+font.descent),
        bounds(-border.toDouble(),-border.toDouble(),labelWidth.toDouble()+border,labelHeight.toDouble()+border),
    ).filter { it.width>0f && it.height>0f }.distinct()
}

/** Replace only the existing atomic link's action bounds; text, selection and callbacks stay owned. */
internal class FigureMissingLinkGeometry(private val label: FloatTextGeometry,
    fragments: List<NativeFloatBounds>, policy: FigureLinkPaint, density: Float, bodyPixels: Float) :
    FloatTextGeometry by label {
    private val bounds = fragments.map { RectF(it.left, it.top, it.right, it.bottom) }
    override val nodes: List<FloatInteractionNode> = listOf(label.nodes.single().let { original ->
        require(original.kind == FloatInteractionKind.LINK && original.onClick != null &&
            original.missingLinkPaint?.fixedPolicy == policy)
        original.copy(bounds = bounds, hitTest = null,
            focusPaint = figureLinkFocusPaint(policy, bounds, density, bodyPixels, connected = true))
    })
    override val extents: NativeGeometryExtents = label.extents.let {
        it.copy(ink = enclosingBounds(it.ink, nativeFocusInk(nodes)),
            interaction = enclosingBounds(it.interaction, nativeBoundsOf(bounds)))
    }
    override fun interactionNodeAt(x: Float, y: Float): FloatInteractionNode? = nodes.single().takeIf { it.contains(x, y) }
    override fun containsInteraction(x: Float, y: Float): Boolean = nodes.single().contains(x, y) ||
        label.rectsForRange(0, label.text.length).any { it.contains(x, y) }
    override fun containsInput(x: Float, y: Float): Boolean = label.containsInput(x, y) || containsInteraction(x, y)
    override val focusBounds: RectF = nativeBoundsOf(bounds)?.let { RectF(it.left, it.top, it.right, it.bottom) }
        ?: label.focusBounds
}
