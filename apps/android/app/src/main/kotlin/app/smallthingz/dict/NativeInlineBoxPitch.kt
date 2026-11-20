package app.smallthingz.dict

/** The retained pitch sources have one relative owner and one or two separated
 * single-character circles. Native layout additionally verifies realized metrics. */
internal fun nativeInlineBoxPitchChildren(owner: Span): List<Span>? {
    fun ordinary(span: Span): Boolean = span.kind == "text" && span.target.isEmpty() &&
        span.trail.isEmpty() && span.direction.isEmpty() && span.tooltip == null &&
        span.image == null && span.ruby == null && span.inlinePaddingGroup == null &&
        span.inlineActionGroup == null && span.clippedAbsolute == null && span.citationMarker == null &&
        !span.isQualifiedCitationBacklink && span.audioControl == null && span.inlineStyle == null &&
        span.linkPaint == null && span.background == null && !span.underline && !span.strike &&
        !span.superscript && !span.subscript
    fun text(span: Span): Boolean = ordinary(span) && span.inlineBoxGroup == null &&
        span.text.isNotEmpty() && span.text.none { it.isWhitespace() || Character.isISOControl(it) ||
            it == '\u061c' || it in '\u200e'..'\u200f' ||
            it in '\u202a'..'\u202e' || it in '\u2066'..'\u2069' }
    fun nonAtomic(box: InlineBoxGroup): Boolean = box.atomicLayout == null &&
        box.atomicAutoLayout == null && box.intrinsicLinesLayout == null
    fun length(value: StyleLength, pixels: Float) = value.unit == StyleLengthUnit.Px && value.value == pixels
    fun edges(value: StyleEdges, pixels: Float) = length(value.top, pixels) && length(value.right, pixels) &&
        length(value.bottom, pixels) && length(value.left, pixels)
    fun stroke(value: InlineBoxBorderEdge) = value is InlineBoxBorderEdge.Solid &&
        length(value.width, 1f) && value.color == InlineBoxColor.CurrentColor
    fun circle(value: InlineBoxBorderEdge) = value is InlineBoxBorderEdge.Dotted &&
        length(value.width, 1f) && (value.color as? InlineBoxColor.Rgb)?.value == "#808080"
    fun inset(value: InlineBoxInset?, unit: StyleWidthUnit, amount: Float) =
        value != null && value.unit == unit && value.value == amount
    val none = InlineBoxBorderEdge.None
    if (!ordinary(owner) || owner.text.isNotEmpty()) return null
    val box = owner.inlineBoxGroup ?: return null
    if (!nonAtomic(box) || box.radius != null || !edges(box.padding, 1f) ||
        !stroke(box.border.top) || box.border.right != none || box.border.bottom != none ||
        box.border.left != none) return null
    val indicator = box.overlays.singleOrNull() ?: return null
    if (indicator.content != null || !inset(indicator.insets.top, StyleWidthUnit.Px, 0f) ||
        !inset(indicator.insets.right, StyleWidthUnit.Percent, 0f) ||
        !inset(indicator.insets.bottom, StyleWidthUnit.Percent, 67f) || indicator.insets.left != null ||
        !stroke(indicator.border.right) || indicator.border.top != none ||
        indicator.border.bottom != none || indicator.border.left != none) return null
    val children = ArrayList<Span>(2)
    var previousCircle = false
    var ordinaryText = false
    for (span in box.spans) {
        val child = span.inlineBoxGroup
        if (child == null) {
            if (!text(span)) return null
            ordinaryText = true
            previousCircle = false
        } else {
            if (previousCircle || children.size == 2 || children.any { it === span } ||
                !ordinary(span) || span.text.isNotEmpty() ||
                !nonAtomic(child) || !edges(child.padding, 0f) || child.overlays.isNotEmpty() ||
                child.radius != StyleWidth(StyleWidthUnit.Percent, 50f) ||
                !circle(child.border.top) || !circle(child.border.right) ||
                !circle(child.border.bottom) || !circle(child.border.left)) return null
            val leaf = child.spans.singleOrNull() ?: return null
            if (!text(leaf) || leaf.text.length != 1 || leaf.text[0] in '\ud800'..'\udfff') return null
            children += span
            previousCircle = true
        }
    }
    return children.takeIf { it.isNotEmpty() && ordinaryText }
}
