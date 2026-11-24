package app.smallthingz.dict


data class Span(
    val kind: String,
    val text: String,
    val target: String = "",
    val trail: String = "",
    val language: String = "",
    val classes: String = "",
    val direction: String = "",
    val bold: Boolean = false,
    val italic: Boolean = false,
    val code: Boolean = false,
    val small: Boolean = false,
    val superscript: Boolean = false,
    val subscript: Boolean = false,
    val strike: Boolean = false,
    val underline: Boolean = false,
    val role: String = "normal",
    val explanation: String = "",
    val foreground: String? = null,
    val background: String? = null,
    val fontScale: Float? = null,
    val fontScaleBasis: FontScaleBasis = FontScaleBasis.Context,
    val image: InlineImage? = null,
    val targetFragment: String? = null,
    val tooltip: String? = null,
    val fontFeatures: FontFeaturePolicy? = null,
    val linkPaint: LinkPaint? = null,
    val inlineStyle: InlineTextStyle? = null,
    val fontFamily: ContainerFontFamily? = null,
    val ruby: Ruby? = null,
    val inlinePaddingGroup: InlinePaddingGroup? = null,
    val inlineActionGroup: InlineActionGroup? = null,
    val inlineBoxGroup: InlineBoxGroup? = null,
    val citationMarker: CitationMarker? = null,
    private val citationBacklinkWitness: CitationBacklinkSpanWitness? = null,
    val audioControl: AudioControl? = null,
    val clippedAbsolute: ClippedAbsoluteInline? = null,
) {
    internal val isQualifiedCitationBacklink: Boolean get() = citationBacklinkWitness != null
    init {
        require(audioControl == null || validAudioControlOwner(this)) { "Invalid audio control owner" }
        require(citationMarker == null || validCitationMarkerSpan(this)) { "Invalid citation marker owner" }
        require(citationBacklinkWitness == null || citationMarker == null && validCitationLinkShape(this)) {
            "Invalid qualified citation backlink copy"
        }
        val citationLocal = citationMarker != null || citationBacklinkWitness != null
        require(!citationLocal || validScopedSpanFields(this)) { "Invalid citation source fields" }
        require(ruby == null || kind == "text" && text.isEmpty() && target.isEmpty() && trail.isEmpty() &&
            targetFragment == null && image == null && inlinePaddingGroup == null && inlineActionGroup == null && inlineBoxGroup == null && clippedAbsolute == null) { "Ruby requires a sole ordinary text owner" }
        require(ruby == null || validRubyChild(this)) { "Invalid ruby owner" }
        inlinePaddingGroup?.let {
            require(text.isEmpty() && trail.isEmpty() && image == null && ruby == null && inlineActionGroup == null && inlineBoxGroup == null && clippedAbsolute == null &&
                validRubyBodyChild(this)) { "Invalid inline padding owner" }
            PresentationSpanVisitor { _, _ -> }.spans(listOf(this))
        }
        inlineActionGroup?.let {
            require(kind in setOf("link", "external_link") && target.isNotEmpty() && text.isEmpty() &&
                trail.isEmpty() && image == null && ruby == null && inlinePaddingGroup == null && inlineBoxGroup == null && clippedAbsolute == null &&
                validRubyBodyChild(this)) { "Invalid inline action owner" }
            PresentationSpanVisitor { _, _ -> }.spans(listOf(this))
        }
        inlineBoxGroup?.let {
            require(text.isEmpty() && trail.isEmpty() && image == null && ruby == null &&
                inlinePaddingGroup == null && inlineActionGroup == null && clippedAbsolute == null && validRubyChild(this)) {
                "Invalid inline box owner"
            }
            PresentationSpanVisitor { _, _ -> }.spans(listOf(this))
        }
        clippedAbsolute?.let {
            require(text.isEmpty() && trail.isEmpty() && image == null && ruby == null &&
                inlinePaddingGroup == null && inlineActionGroup == null && inlineBoxGroup == null && validRubyChild(this)) {
                "Invalid clipped absolute inline owner"
            }
            require(direction.isEmpty() || direction == when (it.staticParentDirection) {
                BidiResolvedDirection.Ltr -> "ltr"
                BidiResolvedDirection.Rtl -> "rtl"
            }) { "Clipped owner direction must match its static parent" }
            PresentationSpanVisitor { _, _ -> }.spans(listOf(this))
        }
        require(tooltip == null || validPresentationString(tooltip)) { "Invalid span tooltip" }
        require(linkPaint == null || kind in setOf("link", "external_link") && (target.isNotEmpty() || citationLocal)) {
            "Source link paint requires an ordinary link action"
        }
        require(linkPaint == null || image == null ||
            image.alt.isNullOrEmpty() && image.map == null && image.staticPoster == null) {
            "Image link paint requires a simple image without alternative text"
        }
        require(linkPaint == null || (foreground == null || foreground == linkPaint.normal.foreground) &&
            underline == linkPaint.normal.underline) { "Source link paint conflicts with its static normal state" }
        require(targetFragment == null || kind == "link") { "Only internal links may carry a target fragment" }
        require(targetFragment == null || validPresentationString(targetFragment)) { "Invalid link target fragment" }
        require(fontScaleBasis != FontScaleBasis.NormalBody || fontScale != null) {
            "Normal-body font scale requires a value"
        }
        require(fontScaleBasis != FontScaleBasis.CssPx ||
            fontScale != null && fontScale.isFinite() && fontScale >= 0f) {
            "CSS-pixel font size requires a finite nonnegative value"
        }
        require(image == null || when (kind) {
            "text" -> target.isEmpty()
            "link", "external_link" -> target.isNotEmpty()
            else -> false
        }) { "Invalid inline image action" }
        require(image == null || (text.isEmpty() && trail.isEmpty())) { "Inline image occurrences cannot also contain text" }
        inlineStyle?.let { policy ->
            require(image == null && when (kind) {
                "text" -> target.isEmpty() && (text.isNotEmpty() || policy.lineHeight != null || ruby != null || inlinePaddingGroup != null || inlineBoxGroup != null || clippedAbsolute != null)
                "link", "external_link" -> (target.isNotEmpty() || citationLocal) && (text.isNotEmpty() || inlinePaddingGroup != null || inlineActionGroup != null || inlineBoxGroup != null || clippedAbsolute != null)
                else -> false
            }) { "Inline effects require an ordinary text owner or an empty line-height strut" }
            require(policy.cursor == null || text.isNotEmpty() || ruby != null || inlinePaddingGroup != null || inlineActionGroup != null || inlineBoxGroup != null || clippedAbsolute != null) { "Empty inline struts cannot own a cursor" }
            require(policy.wrap == null || text.isNotEmpty() || ruby != null || inlinePaddingGroup != null || inlineActionGroup != null || inlineBoxGroup != null || clippedAbsolute != null) { "Empty inline struts cannot own wrapping" }
            require(fontScale == null || fontScale.isFinite() && fontScale >= 0f) { "Invalid inline owner font scale" }
            require(!policy.fontNormalized || fontScale != null && fontScaleBasis != FontScaleBasis.Context) {
                "Normalized inline font requires an explicit non-context scale"
            }
            if (policy.baselineShift != null && policy.lineHeight is InlineLineHeight.FontRelative)
                require(policy.lineHeight.font.matches(this, policy.fontNormalized)) {
                    "Shifted inline line-height owner differs from the run font"
                }
        }
    }
}


/** Explicit navigation identity; labels and array order never supply an occurrence. */
data class CitationTargetStyle(val paint: LinkPaint, val background: FigureColor? = null) {
    init { require(background != FigureColor.NativeTheme) { "Citation target background requires source RGB or transparent" } }
}
data class CitationMarker(val reference: Long, val occurrence: Long, val anchor: String,
    val nowrap: Boolean = false, val isolation: BidiResolvedDirection? = null,
    val targetStyle: CitationTargetStyle? = null) {
    init {
        require(reference in 1L..0xffff_fffeL && occurrence in 1L..0xffff_fffeL &&
            anchor.isNotEmpty() && validPresentationString(anchor)) { "Invalid citation occurrence identity" }
    }
}

/** Opaque construction proof only; neither its value nor its presence is serialized. */
class CitationBacklinkSpanWitness private constructor() {
    companion object {
        private val instance = CitationBacklinkSpanWitness()
        internal fun withPolicies(span: Span, linkPaint: LinkPaint?, inlineStyle: InlineTextStyle?): Span =
            span.copy(linkPaint = linkPaint, inlineStyle = inlineStyle, citationBacklinkWitness = instance)
    }
}

data class ReferenceBacklink private constructor(val occurrence: Long, val span: Span) {
    init {
        require(occurrence in 1L..0xffff_fffeL && span.isQualifiedCitationBacklink && span.citationMarker == null &&
            validCitationSpanLinkPaint(span)) { "Invalid reference backlink" }
    }
    companion object {
        /** The ordinary template supplies every original field; only these local policies need scoped construction. */
        fun withPolicies(occurrence: Long, span: Span, linkPaint: LinkPaint? = span.linkPaint,
            inlineStyle: InlineTextStyle? = span.inlineStyle): ReferenceBacklink =
            ReferenceBacklink(occurrence, CitationBacklinkSpanWitness.withPolicies(span, linkPaint, inlineStyle))
    }
}

internal fun validCitationLinkShape(span: Span): Boolean = span.kind == "link" && span.text.isNotEmpty() &&
    span.target.isEmpty() && span.trail.isEmpty() && span.targetFragment?.let {
        it.isNotEmpty() && validPresentationString(it)
    } == true && span.image == null && span.ruby == null && span.inlinePaddingGroup == null &&
    span.inlineActionGroup == null && span.inlineBoxGroup == null && span.clippedAbsolute == null

internal fun validCitationSpanLinkPaint(span: Span): Boolean = validCitationLinkShape(span) &&
    (span.linkPaint == null || (span.foreground == null || span.foreground == span.linkPaint.normal.foreground) &&
        span.underline == span.linkPaint.normal.underline)

internal fun validCitationMarkerSpan(span: Span): Boolean {
    val marker = span.citationMarker ?: return false
    return validCitationSpanLinkPaint(span) && span.role == "reference" &&
        span.targetFragment == "reference-${marker.reference}" &&
        (marker.isolation == null || span.direction.isEmpty()) &&
        (marker.targetStyle == null || span.linkPaint != null)
}

private fun validScopedSpanFields(span: Span): Boolean =
    span.role in setOf("normal", "label", "pronunciation", "headword", "example", "quotation", "citation", "reference") &&
    listOf(span.text, span.target, span.trail, span.language, span.classes, span.direction,
        span.explanation).all(::validPresentationString) &&
        (span.foreground == null || Regex("#[0-9a-f]{6}").matches(span.foreground)) &&
        (span.background == null || Regex("#[0-9a-f]{6}").matches(span.background)) &&
        (span.fontScale == null || span.fontScale.isFinite() && span.fontScale >= 0f)

/** A proven source AUDIO occurrence; null dimensions and focus retain native automatic policy. */
enum class AudioControlFocusMode { AuthoredNone, UaAuto }
data class AudioControlFocusPaint(val mode: AudioControlFocusMode, val color: FigureColor? = null) {
    init {
        require(color == null || mode == AudioControlFocusMode.UaAuto &&
            (color == FigureColor.Transparent || color is FigureColor.Rgb)) {
            "Audio focus color requires automatic RGB or transparent paint"
        }
    }
}
data class AudioControl(val width: StyleWidth? = null, val height: StyleLength? = null,
    val focus: AudioControlFocusPaint? = null) {
    init {
        require(width == null || width.value.isFinite() && width.value > 0f) { "Invalid audio control width" }
        require(height == null || height.value.isFinite() && height.value > 0f) { "Invalid audio control height" }
    }
}

private fun validAudioControlOwner(span: Span): Boolean {
    if (span.kind != "link" || !span.target.startsWith("File:") || span.target.length == 5 ||
        span.trail.isNotEmpty() || span.targetFragment != null || span.image != null || span.ruby != null ||
        span.inlinePaddingGroup != null || span.inlineActionGroup != null || span.inlineBoxGroup != null ||
        span.citationMarker != null || span.isQualifiedCitationBacklink || span.clippedAbsolute != null || span.linkPaint != null ||
        !validScopedSpanFields(span)) return false
    val classes = span.classes.split(' ', '\t', '\r', '\n', '\u000b', '\u000c')
    if ("wikidict-media" !in classes) return false
    val owner = classes.filter { it.startsWith("wikidict-media-file-") }.singleOrNull() ?: return false
    val expected = buildString {
        append("wikidict-media-file-")
        for (byte in span.target.removePrefix("File:").toByteArray(Charsets.UTF_8)) {
            val value = byte.toInt() and 255
            append("0123456789abcdef"[value ushr 4]); append("0123456789abcdef"[value and 15])
        }
    }
    return owner == expected
}

/** Attached to the existing whole-entry budget walk, including custom Figure content callbacks. */
private class CitationNavigationValidation {
    private var found = false
    private var duplicateReference = false
    private val references = linkedSetOf<Long>()
    private val markers = linkedMapOf<Pair<Long, Long>, String>()
    private val backlinks = linkedMapOf<Pair<Long, Long>, String>()
    private val anchors = hashSetOf<String>()
    private val reserved = hashSetOf<String>()
    fun reserve(anchor: String, fallback: String) {
        if (anchor.isNotEmpty()) reserved += anchor
        if (fallback.isNotEmpty()) reserved += fallback
    }
    fun reference(value: Reference) {
        if (!references.add(value.number)) duplicateReference = true
    }
    fun marker(span: Span) {
        val marker = checkNotNull(span.citationMarker)
        found = true
        require(validCitationMarkerSpan(span)) { "Invalid citation marker" }
        require(markers.put(marker.reference to marker.occurrence, marker.anchor) == null &&
            anchors.add(marker.anchor)) { "Duplicate citation occurrence or return anchor" }
    }
    fun backlink(reference: Reference, value: ReferenceBacklink) {
        found = true
        require(reference.kind == ReferenceKind.Note && value.span.citationMarker == null &&
            validCitationSpanLinkPaint(value.span)) { "Invalid reference backlink owner" }
        require(backlinks.put(reference.number to value.occurrence, checkNotNull(value.span.targetFragment)) == null) {
            "Duplicate reference backlink occurrence"
        }
    }
    fun finish() {
        if (!found) return
        require(!duplicateReference && markers.isNotEmpty() && markers.size == backlinks.size) {
            "Citation markers and backlinks require unique matching reference identities"
        }
        val footers = references.mapTo(hashSetOf()) { "reference-$it" }
        require(footers.none { it in reserved }) { "Reference footer collides with an authored anchor" }
        for ((identity, anchor) in markers) {
            require(identity.first in references && anchor !in reserved && anchor !in footers &&
                backlinks[identity] == anchor) { "Citation return destination does not match its original occurrence" }
        }
    }
}

/** An authored empty clip keeps its source body and static-position box, never a text spacer. */
data class ClippedAbsoluteInline(val width: StyleLength, val height: StyleLength,
    val margin: ContainerMargins, val children: List<Span>, val staticParentDirection: BidiResolvedDirection) {
    init {
        require(listOf(margin.top, margin.right, margin.bottom, margin.left).all { it is ContainerMargin.Length }) {
            "Clipped absolute margins must be definite lengths"
        }
        require(children.isNotEmpty()) { "Clipped absolute inline requires a child" }
        PresentationSpanVisitor { _, _ -> }.clippedAbsolute(this)
    }
}

/** A paint value at the declaring inline boundary; current color remains dynamic. */
sealed interface InlineBoxColor {
    data object CurrentColor : InlineBoxColor
    data object Transparent : InlineBoxColor
    data class Rgb(val value: String) : InlineBoxColor {
        init { require(Regex("#[0-9a-f]{6}").matches(value)) { "Invalid inline box RGB" } }
    }
    data class LightDark(val light: String, val dark: String) : InlineBoxColor {
        init { require(listOf(light, dark).all { Regex("#[0-9a-f]{6}").matches(it) }) { "Invalid inline box theme RGB" } }
    }
}
sealed interface InlineBoxBorderEdge {
    data object None : InlineBoxBorderEdge
    data object Hidden : InlineBoxBorderEdge
    data class Solid(val width: StyleLength, val color: InlineBoxColor) : InlineBoxBorderEdge
    data class Dotted(val width: StyleLength, val color: InlineBoxColor) : InlineBoxBorderEdge
}
data class InlineBoxBorderEdges(val top: InlineBoxBorderEdge, val right: InlineBoxBorderEdge,
    val bottom: InlineBoxBorderEdge, val left: InlineBoxBorderEdge)
/** Offsets are signed. A missing inset is auto, never a stored zero. */
data class InlineBoxInset(val unit: StyleWidthUnit, val value: Float) {
    init { require(value.isFinite()) { "Invalid inline box inset" } }
}
data class InlineBoxInsets(val top: InlineBoxInset? = null, val right: InlineBoxInset? = null,
    val bottom: InlineBoxInset? = null, val left: InlineBoxInset? = null)
/** Detached source text; null line height is independently resolved CSS normal. */
data class InlineBoxOverlayContent(val beforeChild: Long, val ownerFont: InlineFontSnapshot,
    val lineHeight: InlineLineHeight? = null, val textAlign: InlineBoxOverlayTextAlign, val spans: List<Span>) {
    init { require(validInlineBoxOverlayContent(this)) { "Invalid inline box overlay content" } }
}
internal fun validInlineBoxOverlayContent(value: InlineBoxOverlayContent): Boolean {
    val font = value.ownerFont
    if (value.beforeChild !in 0L..0xffff_ffffL || !font.fontNormalized || font.fontScale == null ||
        font.fontScaleBasis == FontScaleBasis.Context || font.small || font.superscript || font.subscript ||
        value.spans.isEmpty() || value.spans.size > (1 shl 20)) return false
    val height = value.lineHeight
    if (height is InlineLineHeight.FontRelative && !sameRubyFont(font, height.font)) return false
    return value.spans.all { child ->
        validRubyBodyChild(child) && child.kind == "text" && child.text.isNotEmpty() && child.target.isEmpty() &&
            child.trail.isEmpty() && child.direction.isEmpty() && child.targetFragment == null &&
            child.ruby == null && child.inlinePaddingGroup == null && child.inlineActionGroup == null &&
            child.inlineBoxGroup == null && child.clippedAbsolute == null && child.citationMarker == null &&
            !child.isQualifiedCitationBacklink && child.background == null && child.inlineStyle == null &&
            child.linkPaint == null && !child.small && !child.superscript && !child.subscript &&
            !child.underline && !child.strike && font.matches(child, normalized = true)
    }
}
/** An absolute decoration may retain detached text without adding parent advance. */
data class InlineBoxOverlay(val insets: InlineBoxInsets, val border: InlineBoxBorderEdges,
    val content: InlineBoxOverlayContent? = null) {
    init {
        require((insets.left != null || insets.right != null) && (insets.top != null || insets.bottom != null)) {
            "Inline box overlay requires an explicit inset on each axis"
        }
    }
}
// Shared alignment for atomic and detached inline-box text.
enum class InlineBoxOverlayTextAlign { Start, Left, Center, Right }

/** Authored atom dimensions use the declaring Box font for em, exactly once. */
data class InlineBoxAtomicLayout(val width: StyleLength, val height: StyleLength,
    val margins: StyleEdges, val boxSizing: ContainerBoxSizing, val textAlign: InlineBoxOverlayTextAlign,
    val wrap: TextWrap, val lineHeight: InlineLineHeight?) {
    init {
        require(width.value > 0f && height.value > 0f) { "Atomic inline box dimensions must be positive" }
        require(wrap == TextWrap.Normal || wrap == TextWrap.BreakWord) { "Unsupported atomic inline box wrapping" }
    }
}

enum class InlineBoxIntrinsicWrap { Normal, Anywhere }

/** Both dimensions are source-auto; maxWidth and em edges use the declaring Box font once. */
data class InlineBoxAtomicAutoLayout(val maxWidth: StyleLength, val margins: StyleEdges,
    val boxSizing: ContainerBoxSizing, val textAlign: InlineBoxOverlayTextAlign, val wrap: TextWrap,
    val intrinsicWrap: InlineBoxIntrinsicWrap, val lineHeight: InlineLineHeight?) {
    init {
        require(maxWidth.value > 0f) { "Automatic inline box maximum width must be positive" }
        require(wrap == TextWrap.Normal || wrap == TextWrap.BreakWord) { "Unsupported automatic inline box wrapping" }
        require(intrinsicWrap != InlineBoxIntrinsicWrap.Anywhere || wrap == TextWrap.BreakWord) {
            "Anywhere intrinsic wrapping requires break-word layout"
        }
        require(when (lineHeight) {
            null -> true
            is InlineLineHeight.Computed -> lineHeight.value.value > 0f
            is InlineLineHeight.FontRelative -> lineHeight.factor > 0f
        }) { "Automatic inline box line height must be positive or proven normal" }
    }
}

/** Signed CSS offsets are local to intrinsic inline lines; ordinary StyleLength stays nonnegative. */
data class InlineBoxSignedLength(val unit: StyleLengthUnit, val value: Float) {
    init { require(value.isFinite()) { "Invalid intrinsic inline signed length" } }
}
enum class InlineBoxIntrinsicLineKind { Sup, Sub }
/** An exclusive original-child boundary; breakAfter owns the source BR without adding a child. */
data class InlineBoxIntrinsicLine(val endChild: Long, val sourceKind: InlineBoxIntrinsicLineKind,
    val breakAfter: Boolean) {
    init { require(endChild in 0L..0xffff_ffffL) { "Invalid intrinsic inline child boundary" } }
}
data class InlineBoxIntrinsicLinesLayout(val marginBottom: InlineBoxSignedLength,
    val verticalAlign: InlineBoxSignedLength, val lineHeight: InlineLineHeight?,
    val textAlign: InlineBoxOverlayTextAlign, val wrap: TextWrap, val lines: List<InlineBoxIntrinsicLine>) {
    init { require(validIntrinsicInlineLines(this)) { "Invalid intrinsic inline source lines" } }
}
private fun validIntrinsicInlineLines(value: InlineBoxIntrinsicLinesLayout): Boolean =
    value.marginBottom.value.isFinite() && value.verticalAlign.value.isFinite() && value.wrap == TextWrap.Normal &&
        value.lines.size == 2 && value.lines[0].endChild == 0L &&
        value.lines[0].sourceKind == InlineBoxIntrinsicLineKind.Sup && value.lines[0].breakAfter &&
        value.lines[1].endChild == 1L && value.lines[1].sourceKind == InlineBoxIntrinsicLineKind.Sub &&
        !value.lines[1].breakAfter && when (val height = value.lineHeight) {
            null -> true
            is InlineLineHeight.Computed -> height.value.value > 0f
            is InlineLineHeight.FontRelative -> height.factor > 0f
        }

private fun sameAtomicLineHeight(first: InlineLineHeight?, second: InlineLineHeight?): Boolean = when (first) {
    null -> second == null
    is InlineLineHeight.Computed -> second is InlineLineHeight.Computed &&
        first.value.value == second.value.value && first.value.fontScaleBasis == second.value.fontScaleBasis
    is InlineLineHeight.FontRelative -> second is InlineLineHeight.FontRelative && first.factor == second.factor &&
        sameRubyFont(first.font, second.font)
}

private fun atomicInlineFont(span: Span): InlineFontSnapshot {
    require(span.inlineStyle?.fontNormalized == true && span.fontScale != null && span.fontScale > 0f &&
        span.fontScaleBasis != FontScaleBasis.Context && !span.small && !span.superscript && !span.subscript) {
        "Atomic inline box requires its known normalized declaring font"
    }
    return InlineFontSnapshot(span.fontScale, span.fontScaleBasis, span.small, span.superscript, span.subscript,
        true, span.bold, span.italic, span.code, span.language, span.classes, span.role, span.fontFeatures, span.fontFamily)
}

private fun validAtomicInlineStyle(span: Span, wrap: TextWrap, lineHeight: InlineLineHeight?): Boolean {
    val style = span.inlineStyle ?: return false
    return style.fontNormalized && !span.underline && !span.strike && style.decoration == null &&
        style.baselineShift == null && style.cursor == null && (style.wrap == null || style.wrap == wrap) &&
        (style.lineHeight == null || sameAtomicLineHeight(style.lineHeight, lineHeight))
}

private fun validAtomicInlineChild(span: Span): Boolean = validRubyBodyChild(span) &&
    span.kind == "text" && span.target.isEmpty() && span.targetFragment == null && span.text.isNotEmpty() &&
    span.text.none { it.code < 0x20 || it == '\u007f' || it == '\u2028' || it == '\u2029' } &&
    span.trail.isEmpty() && span.ruby == null && span.inlinePaddingGroup == null && span.inlineActionGroup == null &&
    span.inlineBoxGroup == null && span.clippedAbsolute == null && span.citationMarker == null && !span.isQualifiedCitationBacklink

private fun requireAtomicInlineOwner(owner: Span, group: InlineBoxGroup) {
    val fixed = group.atomicLayout
    val automatic = group.atomicAutoLayout
    val intrinsic = group.intrinsicLinesLayout
    val wrap = fixed?.wrap ?: automatic?.wrap ?: checkNotNull(intrinsic).wrap
    val height = if (fixed != null) fixed.lineHeight else if (automatic != null) automatic.lineHeight
        else checkNotNull(intrinsic).lineHeight
    require(owner.kind == "text" && owner.target.isEmpty() && owner.targetFragment == null &&
        owner.audioControl == null && owner.citationMarker == null && !owner.isQualifiedCitationBacklink &&
        owner.linkPaint == null && owner.direction in setOf("", "ltr", "rtl") && validAtomicInlineStyle(owner, wrap, height)) {
        "Invalid atomic inline box owner"
    }
    val font = atomicInlineFont(owner)
    require(height !is InlineLineHeight.FontRelative || sameRubyFont(font, height.font)) {
        "Atomic inline line-height font differs from its declaring owner"
    }
    for (child in group.spans) {
        require(sameRubyFont(font, atomicInlineFont(child)) && child.direction == owner.direction &&
            validAtomicInlineStyle(child, wrap, height)) { "Atomic inline child metrics differ from its declaring owner" }
    }
}

/** Absence preserves ordinary baseline participation. */
enum class InlineBoxGroupVerticalAlign { Bottom }

private fun requireBottomInlineOwner(owner: Span, group: InlineBoxGroup) {
    require(owner.kind == "text" && owner.target.isEmpty() && owner.inlineStyle == null && owner.linkPaint == null &&
        owner.direction in setOf("", "ltr", "rtl")) { "Invalid bottom inline owner" }
    fun ordinaryFont(span: Span) = InlineFontSnapshot(span.fontScale, span.fontScaleBasis,
        span.small, span.superscript, span.subscript, false, span.bold, span.italic, span.code,
        span.language, span.classes, span.role, span.fontFeatures, span.fontFamily)
    val font = ordinaryFont(owner)
    require(group.spans.all { child -> sameRubyFont(font, ordinaryFont(child)) &&
        child.underline == owner.underline && child.strike == owner.strike &&
        child.inlineStyle == null && child.linkPaint == null }) { "Bottom inline children differ from their owner font" }
}

/** Child boundaries order detached text; overlay array order also retains authored paint order. */
data class InlineBoxGroup(val padding: StyleEdges, val border: InlineBoxBorderEdges,
    val overlays: List<InlineBoxOverlay> = emptyList(), val spans: List<Span>, val radius: StyleWidth? = null,
    val atomicLayout: InlineBoxAtomicLayout? = null, val atomicAutoLayout: InlineBoxAtomicAutoLayout? = null,
    val intrinsicLinesLayout: InlineBoxIntrinsicLinesLayout? = null,
    val verticalAlign: InlineBoxGroupVerticalAlign? = null) {
    internal val isEmptyTopEdge: Boolean get() = spans.isEmpty() && overlays.isEmpty() && radius == null &&
        atomicLayout == null && atomicAutoLayout == null && intrinsicLinesLayout == null && verticalAlign == null &&
        listOf(padding.top, padding.right, padding.bottom, padding.left).all { it.value == 0f } &&
        border.top == InlineBoxBorderEdge.Solid(StyleLength(StyleLengthUnit.Px, 1f), InlineBoxColor.CurrentColor) &&
        listOf(border.right, border.bottom, border.left).all { it == InlineBoxBorderEdge.None }

    init {
        require(spans.isNotEmpty() || isEmptyTopEdge) { "Inline box requires a child or an exact empty top edge" }
        PresentationSpanVisitor { _, _ -> }.inlineBoxGroup(this)
    }
}

/** The declaring Span owns the edges; only child spans contribute logical text. */
data class InlinePaddingGroup(val left: StyleLength, val right: StyleLength, val spans: List<Span>) {
    init {
        require(left.value >= 0f && right.value >= 0f && (left.value > 0f || right.value > 0f)) {
            "Inline padding requires nonnegative edges and a nonzero edge"
        }
        require(spans.isNotEmpty()) { "Inline padding requires a child" }
        PresentationSpanVisitor { _, _ -> }.inlinePaddingGroup(this)
    }
}

/** One stored action owner; children retain their source text and declaring style. */
data class InlineActionGroup(val spans: List<Span>) {
    init {
        require(spans.isNotEmpty()) { "Inline action requires a child" }
        PresentationSpanVisitor { _, _ -> }.inlineActionGroup(this)
    }
}

/** Compiled base/annotation associations. Graphical and fallback text are separate projections. */
data class Ruby(val segments: List<RubySegment>) {
    init {
        require(segments.isNotEmpty()) { "Ruby requires a segment" }
        require(segments.first().gapBefore.isEmpty()) { "First ruby segment cannot have a gap" }
        PresentationSpanVisitor { _, _ -> }.ruby(this)
    }
}
data class RubySegment(val gapBefore: List<Span>, val bases: List<RubyBase>,
    val annotations: List<RubyAnnotation>) {
    init {
        require(bases.isNotEmpty()) { "Ruby segment requires a base" }
        require(bases.first().gapBefore.isEmpty()) { "First ruby base cannot have a gap" }
        var level = -1L
        var end = 0L
        for (annotation in annotations) {
            require(annotation.baseStart < bases.size.toLong() &&
                annotation.baseCount <= bases.size.toLong() - annotation.baseStart) { "Ruby annotation range is outside its segment" }
            if (annotation.level != level) {
                require(annotation.level == level + 1L) { "Ruby annotation levels must be ordered and dense" }
                require(annotation.gapBefore.isEmpty()) { "First ruby annotation at a level cannot have a gap" }
                level = annotation.level
                end = 0L
            }
            require(annotation.baseStart >= end) { "Ruby annotations overlap or are out of order" }
            end = annotation.baseStart + annotation.baseCount
        }
    }
}
/** Declaring group context contributes metrics and policy, never a synthetic text run. */
data class RubyOwner(val font: InlineFontSnapshot, val direction: String = "",
    val inlineStyle: InlineTextStyle? = null, val foreground: String? = null, val background: String? = null) {
    init {
        require(direction in setOf("", "ltr", "rtl", "auto")) { "Invalid ruby owner direction" }
        require(foreground == null || Regex("#[0-9a-f]{6}").matches(foreground)) { "Invalid ruby owner foreground" }
        require(background == null || Regex("#[0-9a-f]{6}").matches(background)) { "Invalid ruby owner background" }
        inlineStyle?.let { policy ->
            require(!policy.fontNormalized || font.fontNormalized) { "Ruby owner normalized font differs from its style" }
            val height = policy.lineHeight
            if (height is InlineLineHeight.FontRelative) {
                require(sameRubyFont(font, height.font)) { "Ruby line-height font differs from its declaring owner" }
                require(policy.baselineShift == null || policy.fontNormalized == font.fontNormalized) {
                    "Shifted ruby line-height owner differs from its normalized font"
                }
            }
        }
    }
}
private fun sameRubyFont(a: InlineFontSnapshot, b: InlineFontSnapshot): Boolean {
    val aScale = a.fontScale?.takeUnless { it == 1f && a.fontScaleBasis == FontScaleBasis.Context }
    val bScale = b.fontScale?.takeUnless { it == 1f && b.fontScaleBasis == FontScaleBasis.Context }
    return (if (aScale == null) bScale == null else bScale != null && aScale.toDouble() == bScale.toDouble()) &&
        a.fontScaleBasis == b.fontScaleBasis && a.fontNormalized == b.fontNormalized &&
        a.small == b.small && a.superscript == b.superscript && a.subscript == b.subscript &&
        a.bold == b.bold && a.italic == b.italic && a.code == b.code &&
        a.language == b.language && a.classes == b.classes && a.role == b.role &&
        a.fontFeatures == b.fontFeatures && a.fontFamily == b.fontFamily
}
data class RubyBase(val owner: RubyOwner, val gapBefore: List<Span>, val spans: List<Span>)
/** Physical annotation margins; em retains the original annotation owner font basis. */
data class RubyAnnotationMargins(val top: StyleLength, val bottom: StyleLength)
data class RubyAnnotation(val baseStart: Long, val baseCount: Long, val level: Long, val owner: RubyOwner,
    val gapBefore: List<Span>, val spans: List<Span>, val fallbackBefore: List<Span>,
    val fallbackAfter: List<Span>, val explicitFallback: Boolean,
    val margins: RubyAnnotationMargins? = null) {
    init {
        require(baseStart in 0L..0xffff_ffffL && baseCount in 1L..0xffff_ffffL &&
            level in 0L..0xffff_ffffL) { "Invalid ruby annotation association" }
        require(explicitFallback || fallbackBefore.isEmpty() && fallbackAfter.isEmpty()) {
            "Implicit ruby fallback cannot carry explicit runs"
        }
    }
}

/** Gap runs use the ordinary Ruby child domain before their whitespace-only check. */
internal fun validRubyChild(span: Span): Boolean = span.image == null && span.audioControl == null && when (span.kind) {
    "text" -> span.target.isEmpty()
    "link", "external_link" -> span.target.isNotEmpty()
    else -> false
} && span.classes.split(' ', '\t', '\r', '\n', '\u000c').none {
    it == "wikidict-media" || it.startsWith("wikidict-media-file-")
} && validPresentationString(span.text) && validPresentationString(span.trail) &&
    validPresentationString(span.target) && validPresentationString(span.language) &&
    validPresentationString(span.classes) && validPresentationString(span.direction) &&
    validPresentationString(span.explanation) &&
    (span.foreground == null || Regex("#[0-9a-f]{6}").matches(span.foreground)) &&
    (span.background == null || Regex("#[0-9a-f]{6}").matches(span.background)) &&
    (span.fontScale == null || span.fontScale.isFinite() && span.fontScale >= 0f)

/** Source normalization has already resolved body controls; gaps retain their separate CSS domain. */
internal fun validRubyBodyChild(span: Span): Boolean = validRubyChild(span) &&
    span.text.none { it == '\t' || it == '\n' || it == '\r' || it == '\u000c' } &&
    span.trail.none { it == '\t' || it == '\n' || it == '\r' || it == '\u000c' }

internal fun validClippedAbsoluteChild(span: Span): Boolean = validRubyBodyChild(span) &&
    span.ruby == null && span.inlinePaddingGroup == null && span.inlineActionGroup == null &&
    span.inlineBoxGroup == null && span.clippedAbsolute == null && span.citationMarker == null && !span.isQualifiedCitationBacklink

typealias LinkState = FigureLinkState

/** Ordinary links retain all eight source states independently of existing Figure paint. */
data class LinkPaint(val normal: LinkState, val hover: LinkState, val active: LinkState,
    val hoverActive: LinkState, val visited: LinkState, val visitedHover: LinkState,
    val visitedActive: LinkState, val visitedHoverActive: LinkState, val underlineOnFocus: Boolean,
    val focusOutline: FigureFocusOutline? = null) {
    init { require(focusOutline == null || focusOutline.color is FigureColor.Rgb) {
        "Link focus requires its source RGB color"
    } }
    internal fun state(visited: Boolean, hovered: Boolean, active: Boolean): LinkState = when {
        visited && hovered && active -> visitedHoverActive
        visited && active -> visitedActive
        visited && hovered -> visitedHover
        visited -> this.visited
        hovered && active -> hoverActive
        active -> this.active
        hovered -> hover
        else -> normal
    }
}

enum class InlineUnderlineStyle { Solid, Dotted }
data class InlineUnderline(val style: InlineUnderlineStyle, val color: String? = null,
    val thickness: StyleLength? = null) {
    init { require(color == null || Regex("#[0-9a-f]{6}").matches(color)) { "Invalid inline underline RGB" } }
}

/** Source-computed length; legacy table ComputedLineHeight keeps its separate domain. */
data class InlineComputedLength(val value: Float, val fontScaleBasis: FontScaleBasis) {
    init { require(value.isFinite() && fontScaleBasis != FontScaleBasis.Context) { "Invalid computed inline length" } }
}

data class InlineFontSnapshot(val fontScale: Float? = null,
    val fontScaleBasis: FontScaleBasis = FontScaleBasis.Context, val small: Boolean = false,
    val superscript: Boolean = false, val subscript: Boolean = false, val fontNormalized: Boolean = false,
    val bold: Boolean = false, val italic: Boolean = false, val code: Boolean = false,
    val language: String = "", val classes: String = "", val role: String = "normal",
    val fontFeatures: FontFeaturePolicy? = null, val fontFamily: ContainerFontFamily? = null) {
    init {
        require(fontScale == null || fontScale.isFinite() && fontScale >= 0f) { "Invalid inline snapshot font scale" }
        require(fontScaleBasis == FontScaleBasis.Context || fontScale != null) { "Inline snapshot basis requires a scale" }
        require(!fontNormalized || fontScale != null && fontScaleBasis != FontScaleBasis.Context) {
            "Normalized inline snapshot requires an explicit non-context scale"
        }
        require(validPresentationString(language) && '\u0000' !in language &&
            validPresentationString(classes) && '\u0000' !in classes) { "Invalid inline snapshot language or classes" }
        require(role in setOf("normal", "label", "pronunciation", "headword", "example", "quotation", "citation", "reference")) {
            "Unknown inline snapshot role"
        }
    }
    internal fun matches(span: Span, normalized: Boolean): Boolean =
        (if (fontScale == null) span.fontScale == null else span.fontScale?.let { fontScale.toDouble() == it.toDouble() } == true) &&
            fontScaleBasis == span.fontScaleBasis && fontNormalized == normalized &&
            small == span.small && superscript == span.superscript && subscript == span.subscript &&
            bold == span.bold && italic == span.italic && code == span.code &&
            language == span.language && classes == span.classes && role == span.role &&
            fontFeatures == span.fontFeatures && fontFamily == span.fontFamily
}

sealed interface InlineLineHeight {
    data class Computed(val value: InlineComputedLength) : InlineLineHeight {
        init { require(value.value >= 0f) { "Negative inline line height" } }
    }
    data class FontRelative(val factor: Float, val font: InlineFontSnapshot) : InlineLineHeight {
        init { require(factor.isFinite() && factor >= 0f) { "Invalid inline line-height factor" } }
    }
}

enum class TextWrap { Normal, BreakWord, NoWrap }
enum class InlineCursor { Help }
data class InlineTextStyle(val decoration: InlineUnderline? = null, val lineHeight: InlineLineHeight? = null,
    val baselineShift: InlineComputedLength? = null, val fontNormalized: Boolean = false,
    val cursor: InlineCursor? = null, val wrap: TextWrap? = null) {
    init {
        require(wrap != TextWrap.NoWrap) { "No-wrap requires a positioned owner" }
        require(decoration != null || lineHeight != null || baselineShift != null || fontNormalized || cursor != null || wrap != null) {
            "Empty inline text style"
        }
    }
}

/** A compiled internal action. Only absent components use the historical delimiter form. */
data class EntryLink(val target: String, val targetFragment: String? = null) {
    val title: String get() = if (targetFragment == null) target.substringBefore('#') else target
    val fragment: String get() = targetFragment ?: target.substringAfter('#', "")
    val hasFragment: Boolean get() = targetFragment != null || '#' in target
    val local: Boolean get() = title.isEmpty() && hasFragment
}
internal fun Span.entryLink(): EntryLink = EntryLink(target, targetFragment)
internal fun Span.hasInternalAction(): Boolean = kind == "link" &&
    (target.isNotBlank() || !targetFragment.isNullOrEmpty())

enum class FontScaleBasis { Context, NormalBody, CssPx }

enum class ImageDarkModeFilter { InvertHueRotate180 }

enum class StaticPosterPolicy { ThreeDStlV1 }
data class StaticPoster(val policy: StaticPosterPolicy, val label: String, val fileSha1: String,
    val fileTimestamp: String) {
    internal val resourceIdentity get() = Triple(policy, fileSha1, fileTimestamp)
    init {
        require(validPresentationString(label)) { "Invalid static poster label" }
        require(Regex("[0-9a-f]{40}").matches(fileSha1)) { "Invalid static poster file identity" }
        require(Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z").matches(fileTimestamp) &&
            fileTimestamp.take(4) != "0000" && runCatching {
                java.time.LocalDateTime.parse(fileTimestamp.removeSuffix("Z"))
            }.isSuccess) { "Invalid static poster timestamp" }
    }
}

enum class InlineImageVerticalAlign { Middle, Baseline }
/** Source-normalized relative placement; presence also preserves positioned-auto paint order. */
data class InlineImageOccurrenceLayout(val x: ContainerMarginLength, val y: ContainerMarginLength,
    val paddingLeft: StyleLength, val paddingRight: StyleLength)

data class InlineImage(val file: String, val widthPx: Long? = null, val heightPx: Long? = null,
    val alt: String? = null, val tooltip: String? = null, val border: Boolean = false, val map: ImageMap? = null,
    val darkModeFilter: ImageDarkModeFilter? = null, val svgLanguage: String? = null,
    val staticPoster: StaticPoster? = null, val verticalAlign: InlineImageVerticalAlign? = null,
    val occurrenceLayout: InlineImageOccurrenceLayout? = null) {
    init {
        require(file.isNotEmpty() && validPresentationString(file) && file.first() != ' ' && file.last() != ' ' &&
            file.none { it.code < 32 || it.code == 127 || it.code in 0x80..0x9f || it in "[]{}<>|#_" }) { "Invalid inline image file" }
        require(widthPx == null || widthPx in 1L..0xffff_ffffL) { "Invalid inline image width" }
        require(heightPx == null || heightPx in 1L..0xffff_ffffL) { "Invalid inline image height" }
        require(alt == null || validPresentationString(alt)) { "Invalid inline image alt" }
        require(tooltip == null || validPresentationString(tooltip)) { "Invalid inline image tooltip" }
        require(svgLanguage == null || validSvgLanguage(svgLanguage)) { "Invalid SVG raster language" }
        require(occurrenceLayout == null || map == null && staticPoster == null) {
            "Inline image occurrence layout conflicts with map or static poster"
        }
        if (staticPoster != null) {
            require(file.endsWith(".stl", ignoreCase = true) && widthPx != null && heightPx != null &&
                heightPx == (widthPx * 3L + 2L) / 4L) { "Invalid static poster axes or file" }
            require(map == null && darkModeFilter == null && svgLanguage == null && verticalAlign == null) {
                "Unsupported static poster image policy"
            }
        }
    }
}
enum class ImageMapActionKind { Internal, External }
data class ImageMapAction(val kind: ImageMapActionKind, val target: String,
    val targetFragment: String?, val label: String) {
    init {
        require(validPresentationString(target) && validPresentationString(label) &&
            (targetFragment == null || validPresentationString(targetFragment))) { "Invalid image map action text" }
        require(when (kind) {
            ImageMapActionKind.Internal -> target.isNotEmpty() || targetFragment != null
            ImageMapActionKind.External -> target.isNotEmpty() && targetFragment == null
        }) { "Invalid image map action" }
    }
    fun entryLink(): EntryLink {
        require(kind == ImageMapActionKind.Internal)
        return EntryLink(target, targetFragment)
    }
}
enum class ImageMapShape { Rect, Circle, Polygon }
data class ImageMapRegion(val shape: ImageMapShape, val coordinates: List<Double>, val action: ImageMapAction) {
    init {
        require(when (shape) {
            ImageMapShape.Rect -> coordinates.size == 4
            ImageMapShape.Circle -> coordinates.size == 3
            ImageMapShape.Polygon -> coordinates.size >= 6 && coordinates.size % 2 == 0
        }) { "Invalid image map coordinate count" }
        require(coordinates.all { it.isFinite() }) { "Nonfinite image map coordinate" }
    }
}
enum class ImageMapDescription { None, TopRight, BottomRight, BottomLeft, TopLeft }
data class ImageMap(val description: ImageMapDescription, val regions: List<ImageMapRegion>,
    val defaultAction: ImageMapAction? = null)

internal fun validPresentationString(value: String): Boolean {
    var bytes = 0L
    var index = 0
    while (index < value.length) {
        val char = value[index++]
        bytes += when {
            Character.isHighSurrogate(char) -> {
                if (index == value.length || !Character.isLowSurrogate(value[index++])) return false
                4
            }
            Character.isLowSurrogate(char) -> return false
            char.code < 0x80 -> 1
            char.code < 0x800 -> 2
            else -> 3
        }
        if (bytes > 32L * 1024 * 1024) return false
    }
    return true
}

/** Relative to the caller's typography; legacy reduction is applied only once. */
internal fun spanFontScale(span: Span): Float {
    require(span.fontScaleBasis != FontScaleBasis.CssPx) { "CSS pixels are not a font multiplier" }
    return (span.fontScale ?: 1f) * if (span.inlineStyle?.fontNormalized != true && (span.small || span.superscript || span.subscript)) 0.8f else 1f
}

/** Native text policy: retain source pixels, then zoom nominal sp before accessibility conversion. */
internal fun cssPixelNominalFontSp(span: Span, textZoom: Float): Float {
    require(span.fontScaleBasis == FontScaleBasis.CssPx)
    require(textZoom.isFinite() && textZoom > 0f) { "Invalid reader text zoom" }
    val legacy = if (span.inlineStyle?.fontNormalized != true && (span.small || span.superscript || span.subscript)) 0.8 else 1.0
    return (checkNotNull(span.fontScale).toDouble() * textZoom.toDouble() * legacy)
        .coerceAtMost(Float.MAX_VALUE.toDouble()).toFloat()
}

// Blink kMaximumAllowedFontSize / GetComputedSizeFromSpecifiedSize cap computed
// pixels, after the typography/zoom context. This never changes stored scale.
internal const val MaxComputedFontPixels = 10000f
internal fun spanFontPixels(span: Span, contextPixels: Float, normalBodyPixels: Float): Float {
    require(span.fontScaleBasis != FontScaleBasis.CssPx) { "CSS pixels require the native font converter" }
    require(contextPixels.isFinite() && contextPixels >= 0f)
    require(normalBodyPixels.isFinite() && normalBodyPixels >= 0f)
    val scale = span.fontScale ?: 1f
    require(scale.isFinite() && scale >= 0f)
    val base = if (span.fontScaleBasis == FontScaleBasis.NormalBody) normalBodyPixels else contextPixels
    val legacy = if (span.inlineStyle?.fontNormalized != true && (span.small || span.superscript || span.subscript)) 0.8 else 1.0
    return (base.toDouble() * scale.toDouble() * legacy).coerceAtMost(MaxComputedFontPixels.toDouble()).toFloat()
}

internal const val LegacyMaxTableDepth = 16
internal const val MaxTableDepth = 32
internal const val MaxContentDepth = 16

enum class TableWidthUnit { Px, Percent }
data class TableWidth(val unit: TableWidthUnit, val value: Long)
data class TableGeometry(val border: Int? = null, val cellSpacing: Int? = null,
                         val cellPadding: Int? = null, val width: TableWidth? = null)
enum class StyleLengthUnit { Px, Em }
data class StyleLength(override val unit: StyleLengthUnit, override val value: Float) : ContainerMarginLength {
    init { require(value.isFinite() && value >= 0f) { "Invalid table style length" } }
}
data class StyleEdges(override val top: StyleLength, override val right: StyleLength,
    override val bottom: StyleLength, override val left: StyleLength) : ContainerMarginEdges
data class RuleStyle(val height: StyleLength, val fill: ContainerColor, val margins: StyleEdges,
    val clear: FigureClear? = null)
data class BlockStyle(val margins: StyleEdges? = null, val padding: StyleEdges? = null) {
    init { require(margins != null || padding != null) { "Empty block style" } }
}
/** Color of the original TABLE or Cell owner, before descendant text and link paint. */
sealed interface StyleBorderPaint {
    data object OwnerCurrentColor : StyleBorderPaint
    data class Rgb(val value: String) : StyleBorderPaint {
        init { require(Regex("#[0-9a-f]{6}").matches(value)) { "Invalid resolved border RGB" } }
    }
}
/** Complete source edges retain their original stroke until collapsed-border resolution. */
sealed interface ResolvedStyleBorderEdge {
    data object None : ResolvedStyleBorderEdge
    data object Hidden : ResolvedStyleBorderEdge
    data class Solid(val width: StyleLength, val paint: StyleBorderPaint) : ResolvedStyleBorderEdge
    data class Dotted(val width: StyleLength, val paint: StyleBorderPaint) : ResolvedStyleBorderEdge
    data class Inset(val width: StyleLength, val paint: StyleBorderPaint) : ResolvedStyleBorderEdge
    data class Outset(val width: StyleLength, val paint: StyleBorderPaint) : ResolvedStyleBorderEdge
}
sealed interface StyleBorder {
    data object None : StyleBorder
    data class Solid(val width: StyleLength, val color: String) : StyleBorder {
        init { require(Regex("#[0-9a-f]{6}").matches(color)) { "Invalid table border RGB" } }
    }
    data class Edges(val top: StyleBorderEdge, val right: StyleBorderEdge,
        val bottom: StyleBorderEdge, val left: StyleBorderEdge) : StyleBorder
    data class ResolvedEdges(val top: ResolvedStyleBorderEdge, val right: ResolvedStyleBorderEdge,
        val bottom: ResolvedStyleBorderEdge, val left: ResolvedStyleBorderEdge) : StyleBorder
}
sealed interface StyleBorderEdge {
    data object None : StyleBorderEdge
    data object Hidden : StyleBorderEdge
    data class Solid(val width: StyleLength, val color: String) : StyleBorderEdge {
        init { require(Regex("#[0-9a-f]{6}").matches(color)) { "Invalid table border RGB" } }
    }
    data class Dotted(val width: StyleLength, val color: String) : StyleBorderEdge {
        init { require(Regex("#[0-9a-f]{6}").matches(color)) { "Invalid table border RGB" } }
    }
}
sealed interface CellBorder {
    data object None : CellBorder
    data class Solid(val width: StyleLength, val color: String) : CellBorder {
        init { require(Regex("#[0-9a-f]{6}").matches(color)) { "Invalid cell border RGB" } }
    }
    data class Double(val width: StyleLength, val color: String) : CellBorder {
        init { require(Regex("#[0-9a-f]{6}").matches(color)) { "Invalid cell border RGB" } }
    }
}
data class CellBorderEdges(val top: CellBorder? = null, val right: CellBorder? = null,
    val bottom: CellBorder? = null, val left: CellBorder? = null) {
    init { require(top != null || right != null || bottom != null || left != null) { "Empty cell border edges" } }
}
enum class FigureFormat { Thumbnail, Framed }
enum class FigureSizingPolicy { Intrinsic, OriginalWidthWithHeightBound, RequestedFit, RequestedFitCapOriginalWidth }

internal fun validFigureSizingContext(format: FigureFormat, sizing: FigureSizingPolicy,
    width: Long?, height: Long?): Boolean {
    if (width != null && width !in 1L..0xffff_ffffL || height != null && height !in 1L..0xffff_ffffL) return false
    return when (sizing) {
        FigureSizingPolicy.Intrinsic -> format == FigureFormat.Framed
        FigureSizingPolicy.OriginalWidthWithHeightBound -> format == FigureFormat.Framed && height != null
        FigureSizingPolicy.RequestedFit, FigureSizingPolicy.RequestedFitCapOriginalWidth ->
            format == FigureFormat.Thumbnail && width != null
    }
}
enum class FigurePlacement { None, Center, FloatLeft, FloatRight }
enum class FigureClear { None, Left, Right, Both }
sealed interface FigureColor {
    data object NativeTheme : FigureColor
    data object Transparent : FigureColor
    data class Rgb(val value: String) : FigureColor {
        init { require(Regex("#[0-9a-f]{6}").matches(value)) { "Invalid figure RGB" } }
    }
}
sealed interface FigureBorder {
    data object None : FigureBorder
    data class Solid(val width: StyleLength, val color: FigureColor) : FigureBorder
}
enum class MissingLinkPaint { VectorNewLinkV1 }
sealed interface FigureContent {
    val span: Span
    data class Image(override val span: Span, val sizing: FigureSizingPolicy) : FigureContent
    data class Missing(override val span: Span, val width: StyleLength, val lineHeight: StyleLength,
        val linkPaint: MissingLinkPaint? = null) : FigureContent {
        init {
            require(span.text.isNotEmpty() && validPresentationString(span.text) &&
                span.image == null && span.trail.isEmpty() && !span.hasClassToken("wikidict-media")) {
                "Missing figure requires an explicit text label"
            }
            require(when (span.kind) {
                "text" -> span.target.isEmpty()
                "link" -> span.target.isNotEmpty()
                "external_link" -> span.target.isNotEmpty()
                else -> false
            }) { "Invalid missing figure action" }
            require(linkPaint == null || span.linkPaint == null) { "Missing-link paint has two owners" }
            require(linkPaint == null || span.kind in setOf("link", "external_link") && span.foreground == null) {
                "Missing-link paint requires an action without a static foreground"
            }
            require(validPresentationString(span.target) && width.value > 0f && lineHeight.value > 0f) {
                "Invalid missing figure metrics"
            }
        }
    }
}
data class FigureBlockMediaRendition(val url: String, val sha256: String) {
    init {
        require(url.length <= 8192 && url.startsWith("https://") &&
            url.all { it.code in 0x21..0x7e && it != '\\' && it != '#' }) {
            "Invalid Figure block raster URL"
        }
        val path = url.indexOf('/', startIndex = 8)
        require(path > 8 && path + 1 < url.length) { "Figure block raster requires a host and path" }
        val host = url.substring(8, path)
        require(host.first() != '.' && host.last() != '.' && '.' in host && host.all {
            it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '.' || it == '-'
        }) { "Invalid Figure block raster host" }
        require(Regex("[0-9a-f]{64}").matches(sha256)) { "Invalid Figure block raster SHA256" }
    }
}
data class FigureBlockMediaState(val maxWidthPx: Long, val wrapper: ContainerStyle,
    val media: FigureMediaLayout) {
    init {
        require(maxWidthPx in 0L..0xffff_ffffL) { "Invalid Figure block viewport threshold" }
        require(validFigureBlockMediaState(wrapper, media)) { "Unsupported Figure block viewport state" }
    }
}
data class FigureBlockMediaLayout(val wrapper: ContainerStyle, val media: FigureMediaLayout,
    val preferredWidthPx: Long, val naturalWidth: Long, val naturalHeight: Long,
    val rendition1x: FigureBlockMediaRendition, val rendition2x: FigureBlockMediaRendition,
    val viewportStates: List<FigureBlockMediaState> = emptyList()) {
    init {
        require(preferredWidthPx in 1L..0xffff_ffffL && naturalWidth in 1L..0x7fff_ffffL &&
            naturalHeight in 1L..0x7fff_ffffL) { "Invalid Figure block media axes" }
        require(rendition1x.url != rendition2x.url && rendition1x.sha256 != rendition2x.sha256) {
            "Figure block media requires distinct density renditions"
        }
        require(validFigureBlockMediaState(wrapper, media)) { "Unsupported Figure block base state" }
        require(viewportStates.size <= 16 && viewportStates.zipWithNext().all { (a, b) ->
            a.maxWidthPx > b.maxWidthPx
        }) { "Figure block viewport states must be bounded and strictly descending" }
    }
    internal fun stateAtViewport(cssWidth: Double): FigureBlockMediaState? {
        require(cssWidth.isFinite() && cssWidth >= 0.0) { "Invalid Figure block viewport width" }
        return viewportStates.lastOrNull { cssWidth <= it.maxWidthPx.toDouble() }
    }
}
private fun validFigureBlockMediaState(wrapper: ContainerStyle, media: FigureMediaLayout): Boolean =
    wrapper.width == ContainerWidth.Auto && wrapper.lineHeight != null && wrapper.textAlign != null &&
        wrapper.ownerFontScale != null && wrapper.ownerFontScale == media.strut.fontScale &&
        (wrapper.margins != null || wrapper.marginValues != null) &&
        wrapper == ContainerStyle(margins = wrapper.margins, width = wrapper.width,
            lineHeight = wrapper.lineHeight, textAlign = wrapper.textAlign, ownerFontScale = wrapper.ownerFontScale,
            marginValues = wrapper.marginValues) && media.verticalAlign == InlineBoxVerticalAlign.Middle &&
        media.positioning == null && media.after == null && media.focusOutline == null &&
        (media.maxWidth == null || media.maxWidth.percent == 100f && media.maxWidth.subtract.value == 0f)

data class Figure(val content: FigureContent, val format: FigureFormat, val placement: FigurePlacement,
    val clear: FigureClear, val margins: StyleEdges, val imageInsets: StyleEdges, val captionPadding: StyleEdges,
    val captionFontScale: Float, val captionLineHeight: StyleLength,
    val frameBackground: FigureColor, val frameBorder: FigureBorder,
    val imageBackground: FigureColor, val imageBorder: FigureBorder,
    val captionForeground: FigureColor, val captionBackground: FigureColor,
    val caption: List<Span> = emptyList(), val captionBlocks: List<Block>? = null,
    val captionTextAlign: CellTextAlign? = null, val frameMinWidth: StyleLength? = null,
    val tableCaptionLayout: TableCaptionLayout? = null, val blockMediaLayout: FigureBlockMediaLayout? = null) {
    init {
        if (blockMediaLayout != null) {
            require(content is FigureContent.Image && tableCaptionLayout == null &&
                placement == FigurePlacement.None && clear == FigureClear.None && frameMinWidth == null &&
                frameBorder == FigureBorder.None && imageBorder == FigureBorder.None &&
                frameBackground == FigureColor.Transparent && imageBackground == FigureColor.Transparent &&
                captionBackground == FigureColor.Transparent && caption.isEmpty() && captionBlocks.isNullOrEmpty() &&
                captionTextAlign == null && listOf(margins, imageInsets, captionPadding).all { edges ->
                    listOf(edges.top, edges.right, edges.bottom, edges.left).all { it.value == 0f }
                } && content.span.kind == "text" && content.span.target.isEmpty() &&
                content.span.image != null && content.span.image.map == null && content.span.image.staticPoster == null) {
                "Unsupported Figure block-media combination"
            }
        }
        require(tableCaptionLayout == null || frameBorder == FigureBorder.None &&
            (content as? FigureContent.Image)?.span?.image?.staticPoster == null &&
            (content as? FigureContent.Image)?.span?.image?.map == null &&
            tableCaptionLayout.media.validFor(content) &&
            tableCaptionLayout.viewportStates.all { it.media.validFor(content) }) {
            "Unsupported Figure table-caption combination"
        }
        require(frameMinWidth == null || frameMinWidth.unit == StyleLengthUnit.Px) { "Unsupported figure frame minimum unit" }
        val span = content.span
        if (content is FigureContent.Image) {
            require(span.image != null && span.text.isEmpty() && span.trail.isEmpty()) { "Figure requires one image span" }
            require(span.image.verticalAlign == null) { "Inline image alignment is unavailable for Figure media" }
            require(validFigureSizingContext(format, content.sizing, span.image.widthPx, span.image.heightPx)) { "Invalid figure sizing context" }
            require(span.image.staticPoster == null || format == FigureFormat.Thumbnail &&
                content.sizing == FigureSizingPolicy.RequestedFit) { "Unsupported static poster figure mode" }
        }
        require(captionBlocks == null || caption.isEmpty()) { "Rich figure caption owns its content" }
        captionBlocks?.let(::validatePositionedRootBlocks)
        require(captionFontScale.isFinite() && captionFontScale >= 0f) { "Invalid figure caption scale" }
        require(span.fontScale == null || span.fontScale.isFinite() && span.fontScale >= 0f) { "Invalid figure content font scale" }
        require(span.foreground == null || Regex("#[0-9a-f]{6}").matches(span.foreground)) { "Invalid figure content foreground" }
        require(span.background == null || Regex("#[0-9a-f]{6}").matches(span.background)) { "Invalid figure content background" }
        tableCaptionLayout?.missingLinkPaint?.let { policy ->
            require(content is FigureContent.Missing && content.linkPaint == null && span.linkPaint == null &&
                span.kind in setOf("link", "external_link") && span.target.isNotEmpty()) {
                "Source Missing-link paint requires its sole existing label action"
            }
            require(span.foreground == null || span.foreground == policy.normal.foreground) {
                "Source Missing-link paint conflicts with its static foreground"
            }
        }
        tableCaptionLayout?.captionLinkPaint?.let { policy ->
            val visitor = PresentationSpanVisitor { _, _ -> }
            visitor.onSpan = { link ->
                if (link.image == null && link.kind in setOf("link", "external_link")) {
                    require(link.linkPaint == null) { "Caption-link paint has two owners" }
                    require(link.foreground == null || link.foreground == policy.normal.foreground) {
                        "Source caption-link paint conflicts with its static foreground"
                    }
                }
            }
            visitor.visitFigures = false
            if (captionBlocks == null) visitor.spans(caption) else visitor.blocks(captionBlocks)
        }
    }
}

enum class TableCollapse { Separate, Collapse }
enum class CellTextAlign { Left, Center, Right }
enum class TableFloatSide { Left, Right }
enum class TableDisplay { Table, InlineBlock, InlineTable }
enum class TableContainingDirection { Ltr, Rtl }
enum class InlineBoxVerticalAlign { Baseline, Middle, Top }
enum class TableVerticalAlign { Baseline, Middle, Top, Bottom }
enum class CellVerticalAlign { Top, Middle }
/** Computed once at the table origin; a cell font change does not rescale it. */
data class ComputedLineHeight(val value: Float, val fontScaleBasis: FontScaleBasis = FontScaleBasis.Context) {
    init {
        require(value.isFinite() && value > 0f) { "Invalid computed line height" }
        require(fontScaleBasis != FontScaleBasis.CssPx) { "Computed line height does not admit CSS-pixel font origin" }
    }
}
enum class StyleWidthUnit { Px, Em, Percent }
data class StyleWidth(val unit: StyleWidthUnit, val value: Float) {
    init { require(value.isFinite() && value >= 0f) { "Invalid style width" } }
}
/** Physical circular CSS-pixel corners; source lengths remain unrounded. */
data class TableCornerRadii(val topLeft: StyleLength, val topRight: StyleLength,
    val bottomRight: StyleLength, val bottomLeft: StyleLength) {
    init {
        require(listOf(topLeft, topRight, bottomRight, bottomLeft).all {
            it.unit == StyleLengthUnit.Px && it.value.isFinite() && it.value in 0f..16777216f
        }) { "Unsupported table corner radius" }
    }
}
data class TableStyle(val background: String? = null, val border: StyleBorder? = null,
    val collapse: TableCollapse? = null, val margins: StyleEdges? = null, val floatSide: TableFloatSide? = null,
    val width: StyleWidth? = null, val padding: StyleEdges? = null, val clear: FigureClear? = null,
    val display: TableDisplay? = null, val verticalAlign: TableVerticalAlign? = null,
    val lineHeight: ComputedLineHeight? = null, val marginValues: ContainerMargins? = null,
    val containingDirection: TableContainingDirection? = null, val cornerRadii: TableCornerRadii? = null,
    val minWidth: StyleWidth? = null) {
    val isInline: Boolean get() = display == TableDisplay.InlineBlock || display == TableDisplay.InlineTable
    init {
        require(background != null || border != null || collapse != null || margins != null || floatSide != null ||
            width != null || padding != null || clear != null || display != null || verticalAlign != null ||
            lineHeight != null || marginValues != null || cornerRadii != null || minWidth != null) { "Empty table style" }
        require(margins == null || marginValues == null) { "Conflicting table margin representations" }
        val numericCornerDirection = cornerRadii != null && margins != null && marginValues == null
        require((marginValues != null) == (containingDirection != null) ||
            numericCornerDirection && containingDirection != null) { "Table automatic margins require containing direction" }
        marginValues?.let(::validateTableAutoMargins)
        require(!isInline || floatSide == null) { "Inline table cannot also float" }
        require(isInline || (verticalAlign != TableVerticalAlign.Top && verticalAlign != TableVerticalAlign.Bottom)) {
            "Line-edge alignment requires an inline table"
        }
        require(background == null || Regex("#[0-9a-f]{6}").matches(background)) { "Invalid table background RGB" }
        require(cornerRadii == null || !isInline && (border == StyleBorder.None || border is StyleBorder.Solid) &&
            collapse != TableCollapse.Collapse) { "Table corners require explicit uniform separate-border paint" }
    }
}
/** Table's M extension is narrower than the reusable ContainerMargin wire domain. */
internal fun validateTableAutoMargins(value: ContainerMargins) {
    require(value.top is ContainerMargin.Length && value.bottom is ContainerMargin.Length) {
        "Table vertical margins require lengths"
    }
    require(value.left == ContainerMargin.Auto || value.right == ContainerMargin.Auto) {
        "Fixed table margins use the existing representation"
    }
    require(listOf(value.top, value.right, value.bottom, value.left).all {
        it !is ContainerMargin.Length || it.value.value.isFinite() && it.value.value >= 0f
    }) { "Table margins require finite nonnegative lengths" }
}

/** Cell metrics have an explicit origin and admit zero; the older Table domain stays closed. */
data class CellTextStrut(val fontScale: Float, val fontScaleBasis: FontScaleBasis,
    val ownerFont: InlineFontSnapshot? = null) {
    init {
        require(fontScale.isFinite() && fontScale >= 0f && fontScaleBasis != FontScaleBasis.Context)
        ownerFont?.let { font ->
            require(font.fontScale != null && font.fontScale == fontScale && font.fontScaleBasis == fontScaleBasis) {
                "Cell owner font must use the strut's sole size and basis"
            }
            require(font.fontFamily != null && font.fontFeatures != null && font.language.isNotEmpty() &&
                font.language.toByteArray(Charsets.UTF_8).size <= 1024 &&
                !font.small && !font.superscript && !font.subscript && !font.fontNormalized && !font.code &&
                font.classes.isEmpty() && font.role == "normal") { "Incomplete or unsupported cell owner font" }
        }
    }
}
data class CellFixedLineHeight(val value: Float, val fontScaleBasis: FontScaleBasis) {
    init { require(value.isFinite() && value >= 0f && fontScaleBasis != FontScaleBasis.Context) }
}
sealed interface CellLineHeightValue {
    data object Normal : CellLineHeightValue
    data class Multiplier(val value: Float) : CellLineHeightValue {
        init { require(value.isFinite() && value >= 0f) }
    }
    data class Length(val value: CellFixedLineHeight) : CellLineHeightValue
}
data class CellLineHeight(val height: CellLineHeightValue, val strut: CellTextStrut? = null)

/** Explicit enclosing ink; null keeps this cell's established automatic contrast policy. */
enum class CellForeground { Inherit }

data class CellStyle(val border: StyleBorder? = null, val padding: StyleEdges? = null,
    val textAlign: CellTextAlign? = null, val borderEdges: CellBorderEdges? = null,
    val letterSpacing: StyleLength? = null, val width: StyleWidth? = null,
    val minWidth: StyleLength? = null, val verticalAlign: CellVerticalAlign? = null,
    val lineHeight: CellLineHeight? = null, val opacity: Float? = null,
    val foreground: CellForeground? = null) {
    init {
        require(border != null || padding != null || textAlign != null || borderEdges != null ||
            letterSpacing != null || width != null || minWidth != null || verticalAlign != null ||
            lineHeight != null || opacity != null || foreground != null) { "Empty cell style" }
        require(opacity == null || opacity.isFinite() && opacity in 0f..1f) { "Invalid cell opacity" }
        require(border !is StyleBorder.ResolvedEdges || borderEdges == null) {
            "Resolved cell edges cannot also carry per-side border overrides"
        }
    }
}
data class Cell(val spans: List<Span>, val header: Boolean, val colspan: Int, val rowspan: Int,
                val background: String? = null, val nestedTable: Table? = null, val blocks: List<Block>? = null,
                val style: CellStyle? = null) {
    init {
        require(nestedTable == null || spans.isEmpty()) { "A nested table cell cannot also contain spans" }
        require(blocks == null || (spans.isEmpty() && nestedTable == null)) { "Ordered cell blocks cannot also contain legacy content" }
        blocks?.let(::validatePositionedRootBlocks)
    }
}
/** Source TABLE focus-visible paint; it never contributes layout metrics. */
enum class TableScrollFocusMode { AuthoredNone, UaAuto }
data class TableScrollFocusPaint(val mode: TableScrollFocusMode, val color: FigureColor? = null) {
    init { require(color == null || mode == TableScrollFocusMode.UaAuto) {
        "Authored table outline none cannot request a color"
    } }
}

/** Closed Q payload shape, independent of the required focus tail that follows it. */
internal fun tableSeparateCornerViewportShape(maxViewportWidthPx: Long, boxStyle: TableStyle,
    maxWidth: StyleWidth, gridStyle: TableStyle, language: String): Boolean =
    maxViewportWidthPx in 0L..0xffff_ffffL && language.isNotEmpty() && validPresentationString(language) &&
        boxStyle.minWidth == null && gridStyle.minWidth == null &&
        boxStyle.cornerRadii != null && boxStyle.margins != null &&
        boxStyle.width == StyleWidth(StyleWidthUnit.Percent, 100f) &&
        maxWidth == StyleWidth(StyleWidthUnit.Percent, 100f) && boxStyle.marginValues == null &&
        boxStyle.containingDirection != null && boxStyle.floatSide == null && boxStyle.display == null &&
        boxStyle.verticalAlign == null && boxStyle.collapse == null && boxStyle.lineHeight == null &&
        gridStyle.collapse == TableCollapse.Separate && gridStyle.background == null &&
        gridStyle.border == null && gridStyle.padding == null && gridStyle.width == null &&
        gridStyle.margins == null && gridStyle.marginValues == null && gridStyle.containingDirection == null &&
        gridStyle.floatSide == null && gridStyle.clear == null && gridStyle.display == null &&
        gridStyle.verticalAlign == null && gridStyle.lineHeight == null && gridStyle.cornerRadii == null

/** One source block viewport around this Table's existing anonymous grid and caption. */
data class TableBlockViewport(val maxViewportWidthPx: Long, val boxStyle: TableStyle,
    val boxSizing: ContainerBoxSizing, val maxWidth: StyleWidth, val gridStyle: TableStyle,
    val gridDirection: TableContainingDirection, val language: String,
    val focusPaint: TableScrollFocusPaint? = null,
    val intrinsicContainingDirection: TableContainingDirection? = null) {
    /** A separate source grid has explicit geometry on its enclosing Table. */
    internal val isSeparateCornerGrid: Boolean get() = tableSeparateCornerViewportShape(
        maxViewportWidthPx, boxStyle, maxWidth, gridStyle, language)
    init {
        require(boxStyle.minWidth == null && gridStyle.minWidth == null) { "Table viewport styles cannot carry minimum width" }
        require(boxStyle.border !is StyleBorder.ResolvedEdges && gridStyle.border !is StyleBorder.ResolvedEdges) {
            "Resolved borders cannot be converted into table viewport styles"
        }
        require(language.isNotEmpty() && validPresentationString(language)) { "Invalid table source language" }
        require(maxViewportWidthPx in 0L..0xffff_ffffL) { "Invalid table viewport threshold" }
        if (intrinsicContainingDirection != null) {
            require(maxViewportWidthPx > 0L && maxWidth == StyleWidth(StyleWidthUnit.Percent, 100f) &&
                focusPaint != null && boxStyle.cornerRadii == null && gridStyle.lineHeight == null) {
                "Unsupported intrinsic table viewport"
            }
        }
        if (isSeparateCornerGrid) {
            require(focusPaint != null) { "Separate corner viewport requires source scroll focus paint" }
        } else {
            val widthAndMargins = if (focusPaint != null)
                boxStyle.width == null && boxStyle.margins != null && boxStyle.marginValues == null && boxStyle.containingDirection == null
            else boxStyle.width != null && boxStyle.width.value > 0f && boxStyle.marginValues != null && boxStyle.margins == null
            require(widthAndMargins && boxStyle.floatSide == null && boxStyle.display == null &&
                boxStyle.verticalAlign == null && boxStyle.collapse == null && boxStyle.lineHeight == null) {
                "Unsupported table viewport box style"
            }
            require(gridStyle.collapse == TableCollapse.Collapse && gridStyle.background == null &&
                gridStyle.border == null && gridStyle.padding == null && gridStyle.width == null &&
                gridStyle.margins == null && gridStyle.marginValues == null && gridStyle.containingDirection == null &&
                gridStyle.floatSide == null && gridStyle.clear == null && gridStyle.display == null &&
                gridStyle.verticalAlign == null && gridStyle.cornerRadii == null) { "Unsupported anonymous table grid style" }
        }
    }
}

/** One source table changes physical float placement while retaining its existing grid. */
data class TableFloatViewport(val maxViewportWidthPx: Long,
    val containingDirection: TableContainingDirection, val gridDirection: TableContainingDirection,
    val language: String, val narrowClear: FigureClear? = null) {
    init {
        require(maxViewportWidthPx in 1L..0xffff_ffffL) { "Invalid table float viewport threshold" }
        require(language.isNotEmpty() && validPresentationString(language)) { "Invalid table source language" }
    }
}

data class Table(val caption: List<Span>, val rows: List<List<Cell>>, val geometry: TableGeometry? = null,
    val style: TableStyle? = null, val captionBlocks: List<Block>? = null,
    val blockViewport: TableBlockViewport? = null, val floatViewport: TableFloatViewport? = null,
    val rowsHiddenMaxWidthPx: Long? = null) {
    init {
        validateRowsHiddenPolicy()
        validateResolvedBorderOwners()
        require(style?.minWidth == null || blockViewport == null && floatViewport == null) { "Responsive tables cannot carry minimum width" }
        require(style?.cornerRadii == null || style.collapse == TableCollapse.Separate) {
            "Ordinary table corners require explicit separate borders"
        }
        if (blockViewport?.intrinsicContainingDirection != null) {
            val border = geometry?.border
            val spacing = geometry?.cellSpacing
            val padding = geometry?.cellPadding
            require(floatViewport == null && (geometry == null || geometry.width == null &&
                border != null && border in 0..65535 && spacing != null && spacing in 0..65535 &&
                padding != null && padding in 0..65535)) {
                "Intrinsic table viewport permits absent geometry or complete nonfloating legacy hints"
            }
            require(style != null && style.width == null && style.floatSide == null && style.display == null &&
                style.verticalAlign == null && style.lineHeight == null && style.collapse == TableCollapse.Collapse &&
                style.cornerRadii == null && style.margins != null && style.marginValues == null &&
                style.containingDirection == null) {
                "Intrinsic table viewport requires its ordinary automatic-width table"
            }
        } else if (blockViewport?.isSeparateCornerGrid == true) {
            val spacing = geometry?.cellSpacing
            val padding = geometry?.cellPadding
            require(geometry != null && geometry.border == null && geometry.width == null &&
                spacing != null && spacing in 0..65535 && padding != null && padding in 0..65535) {
                "Separate corner grid requires explicit spacing and padding geometry"
            }
            require(floatViewport == null && blockViewport.focusPaint != null && style != null &&
                style.cornerRadii != null && style.collapse == TableCollapse.Separate &&
                !style.isInline && style.floatSide == null && style.margins != null &&
                style.marginValues == null && style.containingDirection != null &&
                style.width == StyleWidth(StyleWidthUnit.Percent, 100f)) {
                "Separate corner viewport requires its nonfloating wide corner table"
            }
        } else if (blockViewport != null && floatViewport != null) {
            require(blockViewport.focusPaint != null && floatViewport.narrowClear == null &&
                blockViewport.maxViewportWidthPx == floatViewport.maxViewportWidthPx &&
                blockViewport.gridDirection == floatViewport.gridDirection && blockViewport.language == floatViewport.language) {
                "Paired table viewports require matching source owners and explicit scroll focus paint"
            }
        } else require(blockViewport == null || blockViewport.focusPaint == null && geometry == null &&
            style?.isInline != true && style?.floatSide == null) {
            "Standalone table block viewport requires nonfloating content without paired focus or legacy geometry"
        }
        if (floatViewport != null) {
            require(geometry == null && caption.isEmpty() && captionBlocks == null &&
                rows.any { it.isNotEmpty() }) { "Table float viewport requires a nonempty captionless grid without legacy geometry" }
            require(style != null && style.floatSide == TableFloatSide.Right && style.margins != null &&
                style.marginValues == null && style.containingDirection == null && style.width?.unit != StyleWidthUnit.Percent &&
                style.padding == null && style.display == null && style.verticalAlign == null && style.lineHeight == null) {
                "Unsupported table float viewport style"
            }
        }
        require(captionBlocks == null || caption.isEmpty()) { "Rich table caption owns its content" }
        captionBlocks?.let(::validatePositionedRootBlocks)
        require(style?.isInline != true || caption.isEmpty() && captionBlocks == null) { "Inline table cannot have a caption" }
        require(style?.isInline != true || rows.any { it.isNotEmpty() }) { "Inline table requires a cell" }
        require(style?.isInline != true || rows.all { row -> row.all(::inlineTableCellShape) }) { "Unsupported inline table cell shape" }
    }
}

/** Each ordinary Table is an independent border owner, including an ordinary nested Table. */
private fun Table.validateResolvedBorderOwners() {
    var resolved = style?.border is StyleBorder.ResolvedEdges
    var mergedCell = false
    rows.forEach { row -> row.forEach { cell ->
        if (cell.style?.border is StyleBorder.ResolvedEdges) resolved = true
        if (cell.rowspan != 1 || cell.colspan != 1) mergedCell = true
    } }
    if (!resolved) return
    require(style?.isInline != true && style?.floatSide == null && style?.cornerRadii == null &&
        blockViewport == null && floatViewport == null) {
        "Resolved borders require an ordinary nonfloating table without a viewport or corners"
    }
    require(!mergedCell) { "Resolved borders require unit spans on every direct cell" }
}

/** Row visibility never removes source rows, captions or their actions from validation. */
private fun Table.validateRowsHiddenPolicy() {
    val bound = rowsHiddenMaxWidthPx ?: return
    require(bound in 1..0xffff_ffffL && rows.isNotEmpty() && style?.isInline != true &&
        style?.floatSide == null && blockViewport == null && floatViewport == null) {
        "Row visibility requires a nonempty ordinary nonfloating table and a positive CSS viewport bound"
    }
}

/** Compare the document CSS viewport before rounding; a narrow cell is not a viewport. */
internal fun Table.blockViewportAt(documentViewportCssPx: Float): TableBlockViewport? =
    blockViewportAt(documentViewportCssPx.toDouble())

internal fun Table.blockViewportAt(documentViewportCssPx: Double): TableBlockViewport? {
    require(documentViewportCssPx.isFinite() && documentViewportCssPx >= 0.0) { "Invalid document CSS viewport" }
    return blockViewport?.takeIf { documentViewportCssPx <= it.maxViewportWidthPx.toDouble() }
}

/** The source table stays immutable; containing direction never mirrors the physical float. */
internal fun Table.effectiveFloatStyle(documentViewportCssPx: Double): TableStyle? {
    val policy = floatViewport ?: return style
    require(documentViewportCssPx.isFinite() && documentViewportCssPx >= 0.0) { "Invalid document CSS viewport" }
    val base = checkNotNull(style)
    return if (documentViewportCssPx <= policy.maxViewportWidthPx.toDouble())
        blockViewport?.boxStyle ?: base.copy(floatSide = null, clear = policy.narrowClear ?: base.clear) else base
}

/** Cells whose existing text/image layout exposes actual intrinsic widths. Wire versions gate new shapes separately. */
internal fun inlineTableCellShape(cell: Cell): Boolean = cell.blocks == null && cell.nestedTable == null &&
    cell.spans.all { span ->
        (span.image == null || span.image.map == null && span.image.staticPoster == null && span.image.darkModeFilter == null &&
            span.image.verticalAlign == null) &&
            !(span.kind != "line_break" && !span.code && span.fontScale != 0f &&
            span.hasClassToken("Egyp") && span.text.codePoints().anyMatch { it in 0x13000..0x13455 })
    }

/** Scope headers are shallow: the one shared visitor owns depth and children. */
enum class BidiMode { Isolate, IsolateOverride }
enum class BidiDirectionInput { Ltr, Rtl, Auto }
enum class BidiResolvedDirection { Ltr, Rtl }
data class BidiScope(val mode: BidiMode, val authoredDirection: BidiDirectionInput?,
    val resolvedDirection: BidiResolvedDirection, val language: String?, val parts: List<FlowPart>) {
    init {
        require(language == null || validPresentationString(language)) { "Invalid scope language" }
        require(when (authoredDirection) {
            BidiDirectionInput.Ltr -> resolvedDirection == BidiResolvedDirection.Ltr
            BidiDirectionInput.Rtl -> resolvedDirection == BidiResolvedDirection.Rtl
            BidiDirectionInput.Auto, null -> mode != BidiMode.IsolateOverride
        }) { "Contradictory compiled bidi scope" }
    }
}
sealed interface FlowPart {
    data class Inline(val spans: List<Span>) : FlowPart
    data class ImageFigure(val figure: Figure) : FlowPart
    data class Scope(val scope: BidiScope) : FlowPart
}
internal fun Block.acceptsAnonymousContent(): Boolean = kind in setOf(
    "list_item", "definition", "example", "quotation", "term", "list_detail", "indent",
) || kind == "paragraph" && depth == 0 && listPath.isEmpty()

/** Existence only: legacy ignored prefixes do not acquire a new validation budget.
 * Work follows the supplied graph; absence is not claimed within the wire item cap.
 * Identity tracking terminates shared/cyclic direct-model graphs without recursion. */
private fun hasAtomicOrOverlayContent(values: List<Span>): Boolean {
    val seen = java.util.IdentityHashMap<Span, Boolean>()
    val work = java.util.ArrayDeque<Iterator<Span>>()
    work.addLast(values.iterator())
    while (work.isNotEmpty()) {
        val cursor = work.peekLast()
        if (!cursor.hasNext()) { work.removeLast(); continue }
        val span = cursor.next()
        if (seen.put(span, true) != null) continue
        val box = span.inlineBoxGroup
        if (box != null) {
            if (box.atomicLayout != null || box.atomicAutoLayout != null || box.intrinsicLinesLayout != null ||
                box.overlays.any { it.content != null }) return true
            work.addLast(box.spans.iterator())
        }
        span.inlinePaddingGroup?.let { work.addLast(it.spans.iterator()) }
        span.inlineActionGroup?.let { work.addLast(it.spans.iterator()) }
        span.clippedAbsolute?.let { work.addLast(it.children.iterator()) }
        span.ruby?.let { ruby ->
            work.addLast(sequence<Span> {
                for (segment in ruby.segments) {
                    yieldAll(segment.gapBefore)
                    for (base in segment.bases) { yieldAll(base.gapBefore); yieldAll(base.spans) }
                    for (annotation in segment.annotations) {
                        yieldAll(annotation.gapBefore); yieldAll(annotation.spans)
                        yieldAll(annotation.fallbackBefore); yieldAll(annotation.fallbackAfter)
                    }
                }
            }.iterator())
        }
    }
    return false
}

/** Authoritative content only. Table depth and content depth never reset at a sink. */
internal class PresentationSpanVisitor(private val visit: (List<Span>, Boolean) -> Unit) {
    var visitFigures = true
    /** Complete Entry validation only; standalone subtrees can precede their eventual ancestor. */
    var validateAbsoluteContainers = false
    private var relativeContainerAvailable = false
    private var staticInlineParent = false
    private var clippedNonstaticAncestor = false
    private fun createsClippedContainingBlock(style: ContainerStyle?): Boolean = style != null &&
        (style.positioning != null || style.absolutePosition != null || style.absoluteStatic != null || style.positionedScope != null)
    private fun createsClippedContainingBlock(figure: Figure): Boolean {
        val table = figure.tableCaptionLayout
        if (table != null && (createsClippedContainingBlock(table.wrapper) || table.media.positioning != null ||
            createsClippedContainingBlock(table.captionBefore) || table.viewportStates.size > 16 || table.viewportStates.any {
                createsClippedContainingBlock(it.wrapper) || it.media.positioning != null || createsClippedContainingBlock(it.captionBefore)
            })) return true
        val block = figure.blockMediaLayout
        return block != null && (createsClippedContainingBlock(block.wrapper) || block.media.positioning != null ||
            block.viewportStates.size > 16 || block.viewportStates.any { createsClippedContainingBlock(it.wrapper) || it.media.positioning != null })
    }
    private inline fun <T> withoutRelativeContainer(read: () -> T): T {
        val previous = relativeContainerAvailable
        val previousStatic = staticInlineParent
        relativeContainerAvailable = false
        staticInlineParent = false
        return try { read() } finally {
            relativeContainerAvailable = previous
            staticInlineParent = previousStatic
        }
    }
    /** Raw semantic validation includes hidden readings and fallback runs; display callbacks stay whole. */
    var onSpan: (Span) -> Unit = {}
    var onCitationMarker: (Span) -> Unit = {}
    var onBlock: (Block) -> Unit = {}
    var onTable: (Table, Int, Int) -> Unit = { _, _, _ -> }
    var onContainer: (Container) -> Unit = {}
    var onFigure: (Figure) -> Unit = {}
    var visitFigureContent: ((FigureContent) -> Unit)? = null
    private var remaining = 1 shl 20
    private var actualTextLeaves = 0
    private fun charge(count: Int) { require(count <= remaining) { "Presentation item budget exceeded" }; remaining -= count }
    fun referenceBatches(values: List<ReferenceBatchPlacement>?) {
        if (values == null) return
        charge(values.size)
        values.forEach { batch ->
            charge(batch.referenceIndices.size)
            batch.layout?.let { layout ->
                charge(1); charge(layout.items.size)
                // Existing ContainerStyle owner-font trailers each charge one item.
                charge(2 + layout.items.size)
            }
        }
    }
    private fun citation(span: Span, backlink: Boolean = false) {
        require(!span.isQualifiedCitationBacklink || backlink) { "Qualified backlink escaped its reference prefix" }
        if (span.citationMarker != null) {
            require(!backlink && validCitationMarkerSpan(span)) { "Invalid citation marker context" }
            charge(1)
            onCitationMarker(span)
        }
    }
    fun backlink(value: ReferenceBacklink) {
        charge(1)
        spanList(listOf(value.span), false, 0, display = true, rubyChild = false, citationBacklink = true)
    }
    private fun descend(depth: Int): Int { require(depth < MaxContentDepth) { "Content nesting is too deep" }; return depth + 1 }
    fun spans(value: List<Span>, preformatted: Boolean = false, contentDepth: Int = 0) {
        spanList(value, preformatted, contentDepth, display = true, rubyChild = false)
    }
    private fun spanList(value: List<Span>, preformatted: Boolean, contentDepth: Int,
        display: Boolean, rubyChild: Boolean, gap: Boolean = false, actionOwner: Span? = null, boxChild: Boolean = false,
        citationBacklink: Boolean = false, clippedChild: Boolean = false) {
        charge(value.size)
        for (span in value) {
            citation(span, citationBacklink)
            require(span.clippedAbsolute == null || !rubyChild && !boxChild && !clippedChild) {
                "Clipped absolute inline cannot nest in a structural inline owner"
            }
            require(span.inlineBoxGroup?.let { it.atomicLayout == null && it.atomicAutoLayout == null &&
                it.intrinsicLinesLayout == null } != false ||
                !rubyChild && !boxChild && !clippedChild && actionOwner == null) {
                "Atomic inline box cannot nest in another structural inline owner"
            }
            if (clippedChild) require(validClippedAbsoluteChild(span)) { "Invalid clipped absolute inline child" }
            if (rubyChild) require(if (gap) validRubyChild(span) else validRubyBodyChild(span)) {
                "Invalid ruby child for its body or gap context"
            }
            if (boxChild) require(validRubyChild(span)) { "Invalid inline box child" }
            if (gap) require(span.kind == "text" && span.target.isEmpty() && span.targetFragment == null &&
                span.image == null && span.ruby == null && span.inlinePaddingGroup == null && span.inlineActionGroup == null && span.inlineBoxGroup == null && span.clippedAbsolute == null && span.trail.isEmpty() && span.text.all {
                    it == ' ' || it == '\t' || it == '\n' || it == '\r' || it == '\u000c'
                }) { "Ruby gaps require CSS whitespace text without actions" }
            require(actionOwner == null || span.kind == "text") { "Inline padding action repeats a descendant action" }
            requirePaddingActionColor(actionOwner, span.foreground)
            if (span.image?.occurrenceLayout != null) charge(1)
            span.audioControl?.let { charge(1); if (it.focus != null) charge(1) }
            onSpan(span)
            if (span.text.isNotEmpty() || span.trail.isNotEmpty()) actualTextLeaves++
            span.ruby?.let { ruby(it, contentDepth, actionOwner) }
            span.inlinePaddingGroup?.let {
                inlinePaddingGroup(it, contentDepth, actionOwner ?: span.takeIf { it.kind in setOf("link", "external_link") })
            }
            span.inlineActionGroup?.let { inlineActionGroup(it, contentDepth, actionOwner ?: span) }
            span.inlineBoxGroup?.let {
                if (it.spans.isEmpty()) require(!rubyChild && !boxChild && !clippedChild && actionOwner == null &&
                    span.kind == "text" && span.target.isEmpty() && span.targetFragment == null && span.tooltip == null &&
                    span.explanation.isEmpty() && span.inlineStyle == null) { "Empty inline top edge needs its own plain source position" }
                inlineBoxGroup(it, contentDepth, actionOwner ?: span.takeIf { it.kind in setOf("link", "external_link") },
                    strictBody = rubyChild, owner = span)
            }
            span.clippedAbsolute?.let {
                clippedAbsolute(it, contentDepth, span.takeIf { it.kind in setOf("link", "external_link") })
            }
        }
        if (display) visit(value, preformatted)
    }
    private fun requirePaddingActionColor(owner: Span?, foreground: String?) {
        val source = owner ?: return
        val paint = source.linkPaint ?: return
        require(foreground == null || foreground == (source.foreground ?: paint.normal.foreground)) {
            "Inline padding action conflicts with descendant foreground"
        }
    }
    fun bodyTypography(value: BodyTypography?) { if (value != null) charge(1) }
    fun clippedAbsolute(value: ClippedAbsoluteInline, contentDepth: Int = 0, actionOwner: Span? = null) {
        require(!clippedNonstaticAncestor) { "Clipped absolute inline requires static ancestry to the Entry root" }
        val depth = descend(contentDepth)
        val before = actualTextLeaves
        spanList(value.children, false, depth, display = false, rubyChild = false, clippedChild = true,
            actionOwner = actionOwner)
        require(actualTextLeaves != before) { "Clipped absolute inline requires actual child text or trail" }
    }
    fun inlineBoxGroup(value: InlineBoxGroup, contentDepth: Int = 0, actionOwner: Span? = null,
        strictBody: Boolean = false, owner: Span? = null) {
        require(listOf(value.atomicLayout, value.atomicAutoLayout, value.intrinsicLinesLayout).count { it != null } <= 1) {
            "Inline box atomic variants are exclusive"
        }
        if (value.verticalAlign != null) {
            val edge = value.border.top as? InlineBoxBorderEdge.Dotted
            require(value.atomicLayout == null && value.atomicAutoLayout == null && value.intrinsicLinesLayout == null &&
                value.radius == null && value.overlays.isEmpty() && value.padding.top.value == 0f &&
                value.padding.bottom.value == 0f && value.padding.left == value.padding.right &&
                edge != null && edge.width.value > 0f && edge.color is InlineBoxColor.Rgb &&
                listOf(value.border.right, value.border.bottom, value.border.left).all { it == edge } &&
                value.spans.all { validAtomicInlineChild(it) && it.inlineStyle == null && it.linkPaint == null }) {
                "Bottom inline box requires plain text, equal dotted RGB edges and horizontal padding"
            }
            if (owner != null) requireBottomInlineOwner(owner, value)
        }
        value.intrinsicLinesLayout?.let { intrinsic ->
            charge(2) // Both original source-line descriptors, in addition to the shared atomic record below.
            require(validIntrinsicInlineLines(intrinsic) && value.spans.size == 1 &&
                value.spans[0].text.length == 1 && value.spans[0].text[0] in '0'..'9' &&
                listOf(value.padding.top, value.padding.right, value.padding.bottom, value.padding.left).all { it.value == 0f } &&
                listOf(value.border.top, value.border.right, value.border.bottom, value.border.left).all { it == InlineBoxBorderEdge.None }) {
                "Intrinsic inline lines require an empty first source line and one undecorated original digit"
            }
        }
        if (value.atomicLayout != null || value.atomicAutoLayout != null || value.intrinsicLinesLayout != null) {
            charge(1)
            require(value.spans.size <= remaining) { "Atomic inline children exceed the presentation budget" }
            require(!strictBody && actionOwner == null && value.radius == null && value.overlays.isEmpty() &&
                value.spans.all(::validAtomicInlineChild) && value.spans.any { child -> child.text.any { it != ' ' } }) {
                "Atomic inline box requires plain noncollapsible source text without nested owners or decoration overlays"
            }
            if (owner != null) requireAtomicInlineOwner(owner, value)
        }
        value.radius?.let { radius ->
            require(radius.unit == StyleWidthUnit.Px || radius.unit == StyleWidthUnit.Percent) {
                "Inline box radius requires CSS pixels or percent"
            }
            val other = listOf(value.border.right, value.border.bottom, value.border.left)
            require(value.overlays.isEmpty() && when (val first = value.border.top) {
                is InlineBoxBorderEdge.Solid -> first.color is InlineBoxColor.Rgb && other.all { edge ->
                    edge is InlineBoxBorderEdge.Solid && edge.width.unit == first.width.unit &&
                        edge.width.value == first.width.value && edge.color == first.color
                }
                is InlineBoxBorderEdge.Dotted -> first.color is InlineBoxColor.Rgb && other.all { edge ->
                    edge is InlineBoxBorderEdge.Dotted && edge.width.unit == first.width.unit &&
                        edge.width.value == first.width.value && edge.color == first.color
                }
                else -> false
            }) { "Rounded inline box requires four equal solid or dotted RGB borders without overlays" }
        }
        val depth = descend(contentDepth)
        charge(value.overlays.size)
        var previousBoundary = 0L
        for (overlay in value.overlays) overlay.content?.let { body ->
            require(actionOwner == null) { "Inline overlay text cannot inherit an action" }
            require(validInlineBoxOverlayContent(body) && body.beforeChild >= previousBoundary &&
                body.beforeChild <= value.spans.size.toLong()) { "Invalid inline overlay body or source boundary" }
            previousBoundary = body.beforeChild
            val beforeOverlay = actualTextLeaves
            spanList(body.spans, false, descend(depth), display = false, rubyChild = true)
            // Detached text never satisfies the containing Box's in-flow text requirement.
            actualTextLeaves = beforeOverlay
        }
        val before = actualTextLeaves
        spanList(value.spans, false, depth, display = false, rubyChild = strictBody, boxChild = true,
            actionOwner = actionOwner)
        require(actualTextLeaves != before || value.isEmptyTopEdge) { "Inline box requires actual child text or an empty top edge" }
    }
    fun inlinePaddingGroup(value: InlinePaddingGroup, contentDepth: Int = 0, actionOwner: Span? = null) {
        spanList(value.spans, false, descend(contentDepth), display = false, rubyChild = true,
            actionOwner = actionOwner)
    }
    fun inlineActionGroup(value: InlineActionGroup, contentDepth: Int = 0, actionOwner: Span? = null) {
        spanList(value.spans, false, descend(contentDepth), display = false, rubyChild = true,
            actionOwner = actionOwner)
    }
    fun ruby(value: Ruby, contentDepth: Int = 0, actionOwner: Span? = null) {
        val depth = descend(contentDepth)
        charge(value.segments.size)
        fun runs(spans: List<Span>, gap: Boolean = false) =
            spanList(spans, false, depth, display = false, rubyChild = true, gap = gap, actionOwner = actionOwner)
        for (segment in value.segments) {
            runs(segment.gapBefore, gap = true)
            charge(segment.bases.size)
            for (base in segment.bases) {
                runs(base.gapBefore, gap = true); charge(1)
                requirePaddingActionColor(actionOwner, base.owner.foreground)
                runs(base.spans)
            }
            charge(segment.annotations.size)
            for (annotation in segment.annotations) {
                charge(1)
                requirePaddingActionColor(actionOwner, annotation.owner.foreground)
                runs(annotation.gapBefore, gap = true); runs(annotation.spans)
                runs(annotation.fallbackBefore); runs(annotation.fallbackAfter)
            }
        }
    }
    fun blocks(value: List<Block>, tableDepth: Int = 0, contentDepth: Int = 0) {
        charge(value.size); value.forEach { block(it, tableDepth, contentDepth) }
    }
    fun block(value: Block, tableDepth: Int = 0, contentDepth: Int = 0) {
        onBlock(value)
        // Legacy rendering ignores these prefix runs. New typed custody still validates
        // their serialized owners and budgets without invoking display callbacks.
        if ((value.table != null || value.kind == "rule") &&
            (value.spans.any { it.audioControl != null || it.clippedAbsolute != null } || hasAtomicOrOverlayContent(value.spans)))
            spanList(value.spans, false, contentDepth, display = false, rubyChild = false)
        when {
            value.container != null -> {
                require(validContainerDisclosureOwner(value.container)) { "Invalid original disclosure child" }
                value.container.disclosure?.let {
                    charge(1)
                    if (it.focus != null) charge(1)
                    if (it.expandRun != null) charge(1)
                    if (it.collapseRun != null) charge(1)
                }
                if (value.container.style.ownerFont != null) charge(1)
                val previous = relativeContainerAvailable
                val previousStatic = staticInlineParent
                val style = value.container.style
                if (validateAbsoluteContainers && style.absoluteStatic != null) {
                    require(previousStatic && validContainerAbsoluteStaticBody(value.container)) {
                        "Static inline Container requires its sole immediate relative parent"
                    }
                }
                if (validateAbsoluteContainers && (style.absolutePosition != null || style.absoluteStatic != null)) {
                    require(style.absolutePosition == null || previous) { "Absolute Container requires a represented relative ancestor" }
                    relativeContainerAvailable = false
                } else if (style.positioning == ContainerPositioning.RelativeAuto) relativeContainerAvailable = true
                staticInlineParent = value.container.blocks.size == 1 && validContainerStaticParentStyle(style)
                val previousClipped = clippedNonstaticAncestor
                clippedNonstaticAncestor = previousClipped || createsClippedContainingBlock(style)
                try {
                    onContainer(value.container)
                    blocks(value.container.blocks, tableDepth, descend(contentDepth))
                } finally {
                    relativeContainerAvailable = previous
                    staticInlineParent = previousStatic
                    clippedNonstaticAncestor = previousClipped
                }
            }
            value.table != null -> table(value.table, tableDepth + 1, contentDepth)
            value.figure != null -> figure(value.figure, tableDepth, contentDepth)
            value.flow != null -> parts(value.flow, tableDepth, descend(contentDepth))
            value.kind != "rule" -> spans(value.spans, value.kind == "preformatted", contentDepth)
        }
    }
    fun figure(value: Figure, tableDepth: Int, contentDepth: Int): Unit = withoutRelativeContainer {
        if (!visitFigures) return@withoutRelativeContainer
        val previousClipped = clippedNonstaticAncestor
        clippedNonstaticAncestor = previousClipped || createsClippedContainingBlock(value)
        try {
            onFigure(value)
            val contentVisitor = visitFigureContent
            if (contentVisitor == null) spans(listOf(value.content.span), contentDepth = contentDepth)
            else {
                charge(1)
                citation(value.content.span)
                if (value.content.span.image?.occurrenceLayout != null) charge(1)
                // The custom callback owns the root image occurrence, including Figure sizing.
                // Descendants still share this visitor's budget without displaying them twice.
                value.content.span.ruby?.let { ruby(it, contentDepth) }
                value.content.span.inlinePaddingGroup?.let {
                    inlinePaddingGroup(it, contentDepth, value.content.span.takeIf { it.kind in setOf("link", "external_link") })
                }
                value.content.span.inlineActionGroup?.let { inlineActionGroup(it, contentDepth, value.content.span) }
                value.content.span.inlineBoxGroup?.let {
                    inlineBoxGroup(it, contentDepth, value.content.span.takeIf { it.kind in setOf("link", "external_link") },
                        owner = value.content.span)
                }
                value.content.span.clippedAbsolute?.let {
                    clippedAbsolute(it, contentDepth, value.content.span.takeIf { it.kind in setOf("link", "external_link") })
                }
                contentVisitor(value.content)
            }
            val rich = value.captionBlocks
            if (rich == null) spans(value.caption, contentDepth = contentDepth) else blocks(rich, tableDepth, descend(contentDepth))
        } finally {
            clippedNonstaticAncestor = previousClipped
        }
    }
    fun parts(value: List<FlowPart>, tableDepth: Int, contentDepth: Int) {
        charge(value.size)
        value.forEach { part -> when (part) {
            is FlowPart.Inline -> spans(part.spans, contentDepth = contentDepth)
            is FlowPart.ImageFigure -> figure(part.figure, tableDepth, contentDepth)
            is FlowPart.Scope -> parts(part.scope.parts, tableDepth, descend(contentDepth))
        } }
    }
    fun table(value: Table, tableDepth: Int = 1, contentDepth: Int = 0): Unit = withoutRelativeContainer {
        require(tableDepth <= MaxTableDepth) { "Table nesting is too deep" }
        value.validateRowsHiddenPolicy()
        value.validateResolvedBorderOwners()
        if (value.rowsHiddenMaxWidthPx != null) charge(1)
        onTable(value, tableDepth, contentDepth)
        val rich = value.captionBlocks
        if (rich == null) spans(value.caption, contentDepth = contentDepth) else blocks(rich, tableDepth, descend(contentDepth))
        charge(value.rows.size)
        value.rows.forEach { row -> charge(row.size); row.forEach { cell ->
            when {
                cell.blocks != null -> blocks(cell.blocks, tableDepth, contentDepth)
                cell.nestedTable != null -> table(cell.nestedTable, tableDepth + 1, contentDepth)
                else -> spans(cell.spans, contentDepth = contentDepth)
            }
        } }
    }
}
internal fun Block.visitSpanRuns(visit: (List<Span>, Boolean) -> Unit) = PresentationSpanVisitor(visit).block(this)
internal fun Table.visitSpanRuns(visit: (List<Span>, Boolean) -> Unit) = PresentationSpanVisitor(visit).table(this)
internal fun Table.visitSpans(visit: (List<Span>) -> Unit) = visitSpanRuns { spans, _ -> visit(spans) }
enum class ColumnBreakInside { Auto, Avoid }

data class Block(
    val kind: String,
    val depth: Int,
    val spans: List<Span>,
    val listPath: String = "",
    val number: String = "",
    val table: Table? = null,
    val feature: Feature? = null,
    val level: Int = 0,
    val anchor: String = "",
    val anchorFallback: String = "",
    val textAlign: CellTextAlign? = null,
    val style: BlockStyle? = null,
    val figure: Figure? = null,
    val flow: List<FlowPart>? = null,
    val container: Container? = null,
    val ruleStyle: RuleStyle? = null,
    val columnBreakInside: ColumnBreakInside? = null,
) {
    init {
        require(columnBreakInside == null || kind in setOf("paragraph", "definition", "example", "quotation",
            "list_item", "list_detail", "indent", "term") && table == null && feature == null &&
            figure == null && flow == null && container == null && ruleStyle == null) {
            "Column break policy requires an ordinary text block"
        }
        require(ruleStyle == null || kind == "rule" && depth == 0 && level == 0 && spans.isEmpty() &&
            listPath.isEmpty() && number.isEmpty() && anchor.isEmpty() && anchorFallback.isEmpty() &&
            feature == null && table == null && figure == null && flow == null && container == null &&
            style == null && textAlign == null) { "Authored rule requires its sole ordinary empty block" }
        require((kind == "container") == (container != null)) { "Container kind requires its sole content owner" }
        require(container == null || depth == 0 && spans.isEmpty() && listPath.isEmpty() && number.isEmpty() &&
            table == null && feature == null && level == 0 && anchor.isEmpty() && anchorFallback.isEmpty() &&
            textAlign == null && style == null && figure == null && flow == null) { "Invalid container wrapper" }
        require(table?.style?.isInline != true || kind in setOf("table", "list_item") && spans.isEmpty() && feature == null) { "Inline table requires sole ordinary block content" }
        require(figure == null || (spans.isEmpty() && table == null && feature == null && style == null &&
            flow == null && acceptsAnonymousContent())) { "Figure requires one content owner" }
        require(flow == null || (spans.isEmpty() && table == null && feature == null && figure == null &&
            acceptsAnonymousContent())) { "Anonymous flow requires one content owner" }
        require(style == null || (kind == "paragraph" && depth == 0 && listPath.isEmpty() && table == null && feature == null)) {
            "Block style requires an ordinary paragraph"
        }
    }
}
/** Container descendants validate their direct parent; each independent body starts without one. */
private fun validatePositionedRootBlocks(blocks: List<Block>) {
    require(blocks.none { it.container?.style?.positioning is ContainerPositioning.Absolute }) {
        "Absolute text requires a direct positioned containing scope"
    }
}
data class Feature(val kind: String, val language: String, val data: String, val tailKind: String, val tail: String)
data class HeadingAnchorReveal(val primaryTop: StyleLength, val fallbackTop: StyleLength? = null) {
    init { require(primaryTop.unit == StyleLengthUnit.Px &&
        (fallbackTop == null || fallbackTop.unit == StyleLengthUnit.Px)) { "Heading reveal offsets require CSS pixels" } }
}

data class SectionHeadingStyle(val box: ContainerStyle, val font: InlineFontSnapshot,
    val direction: BidiResolvedDirection, val titleWrap: TextWrap? = null,
    val anchorReveal: HeadingAnchorReveal? = null) {
    init {
        require(titleWrap != TextWrap.NoWrap) { "Heading no-wrap is unsupported" }
        require(box.margins != null && box.padding != null && box.border != null &&
            box.ownerFontScale != null && box.lineHeight != null && box.fontFamily != null && box.clear != null) {
            "Heading box requires computed margins, padding, border, font, line height and clear"
        }
        require((box.width == null || box.width == ContainerWidth.Auto) &&
            (box.maxWidth == null || box.maxWidth == ContainerMaxWidth.None) &&
            (box.layout == null || box.layout == ContainerLayout.Flow) &&
            (box.overflow == null || box.overflow == ContainerOverflow.Visible) &&
            box.floatSide == null && box.flexItem == null && box.alignItems == null && box.columns == null &&
            box.positioning == null && box.screenMaxWidth == null && box.height == null &&
            box.minHeight == null && box.marginValues == null && box.ownerFont == null &&
            box.absolutePosition == null && box.absoluteStatic == null && box.textWrap == null) { "Unsupported heading box" }
        require(font.fontScale != null && font.fontScaleBasis == FontScaleBasis.NormalBody &&
            font.fontScale == box.ownerFontScale && font.language.isNotEmpty() &&
            font.language.toByteArray(Charsets.UTF_8).size <= 1024 && font.role == "normal" &&
            font.classes.isEmpty() && !font.small && !font.superscript && !font.subscript &&
            !font.fontNormalized && !font.code &&
            (font.fontFamily == null || font.fontFamily == box.fontFamily)) { "Invalid heading owner font" }
    }
}
data class Section(val level: Int, val title: String, val blocks: List<Block>, val anchor: String = "",
    val anchorFallback: String = "", val headingStyle: SectionHeadingStyle? = null) {
    init {
        validatePositionedRootBlocks(blocks)
        if (headingStyle != null) {
            headingStyle.anchorReveal?.let { reveal ->
                require(anchor.isNotEmpty() && (reveal.fallbackTop != null) == anchorFallback.isNotEmpty() &&
                    (anchorFallback.isEmpty() || anchorFallback != anchor)) { "Heading reveal requires distinct represented anchor identities" }
            }
            val companion = blocks.firstOrNull()
            require(companion != null && companion.kind == "heading" && companion.depth == 0 &&
                companion.level == level && companion.anchor == anchor && companion.anchorFallback == anchorFallback &&
                companion.listPath.isEmpty() && companion.number.isEmpty() && companion.feature == null &&
                companion.table == null && companion.flow == null && companion.container == null &&
                companion.figure == null && companion.style == null && companion.ruleStyle == null &&
                companion.textAlign == null && companion.spans.isNotEmpty() && companion.spans.all {
                    it.kind in setOf("text", "link", "external_link") && (it.text.isNotEmpty() || it.ruby != null || it.inlinePaddingGroup != null || it.inlineActionGroup != null || it.inlineBoxGroup != null || it.clippedAbsolute != null) &&
                        it.trail.isEmpty() && (it.ruby != null || it.inlinePaddingGroup != null || it.inlineActionGroup != null || it.inlineBoxGroup != null || it.clippedAbsolute != null || it.direction.isEmpty())
                } && (if (companion.spans.any { it.ruby != null || it.inlinePaddingGroup != null || it.inlineActionGroup != null || it.inlineBoxGroup != null || it.clippedAbsolute != null }) rubyFallbackText(companion.spans)
                    else companion.spans.joinToString("") { it.text }) == title) { "Invalid authored heading companion" }
        }
    }
}
data class Media(val file: String, val kind: String, val caption: String)
enum class ReferenceKind { Note, Fragment }
data class Reference(val number: Long, val groupNumber: Long?, val group: String, val spans: List<Span>,
    val kind: ReferenceKind = ReferenceKind.Note, val blocks: List<Block>? = null,
    val bodyTypography: BodyTypography? = null, val backlinks: List<ReferenceBacklink> = emptyList()) {
    init {
        require(backlinks.isEmpty() || kind == ReferenceKind.Note) { "Only notes may own citation backlinks" }
        require(blocks == null || spans.isEmpty()) { "Ordered reference blocks cannot also contain legacy spans" }
        blocks?.let(::validatePositionedRootBlocks)
        require(number in 1L..0xffff_fffeL) { "Reference item identity is outside the wire range" }
        require(if (kind == ReferenceKind.Note) groupNumber != null && groupNumber in 1L..0xffff_fffeL else groupNumber == null) {
            "Only numbered notes have a valid wire group ordinal"
        }
    }
}
/** Original section/block boundaries; indices retain authored flush order, not numeric order. */
data class ReferenceBatchPlacement(val sectionIndex: Int, val beforeBlockIndex: Int,
    val referenceIndices: List<Int>, val layout: ReferenceBatchLayout? = null)

internal fun validateReferenceBatchPlacements(sections: List<Section>, references: List<Reference>,
    batches: List<ReferenceBatchPlacement>?, adjoining: BodyAdjoiningPolicy?) {
    if (batches == null) return
    require((adjoining == null || batches.all { it.layout != null }) && batches.isNotEmpty() && batches.size <= (1 shl 20) &&
        references.isNotEmpty() && references.size <= (1 shl 20)) { "Invalid explicit reference batch owner" }
    val seen = BooleanArray(references.size)
    var used = 0
    var previous: ReferenceBatchPlacement? = null
    for (batch in batches) {
        require(batch.sectionIndex in sections.indices &&
            batch.beforeBlockIndex in 0..sections[batch.sectionIndex].blocks.size &&
            batch.referenceIndices.isNotEmpty() && batch.referenceIndices.size <= references.size - used) {
            "Invalid reference batch boundary or size"
        }
        previous?.let { prior -> require(batch.sectionIndex > prior.sectionIndex ||
            batch.sectionIndex == prior.sectionIndex && batch.beforeBlockIndex >= prior.beforeBlockIndex) {
            "Reference batch boundaries are out of order"
        } }
        for (index in batch.referenceIndices) {
            require(index in references.indices && references[index].kind == ReferenceKind.Note && !seen[index]) {
                "Reference batch requires each note exactly once"
            }
            seen[index] = true
            used++
        }
        batch.layout?.let { validateReferenceBatchLayout(it, batch.referenceIndices, references) }
        previous = batch
    }
    require(used == references.size) { "Reference batch census is incomplete" }
}

internal fun Reference.visitSpanRuns(visit: (List<Span>, Boolean) -> Unit) {
    val content = blocks
    if (backlinks.isEmpty()) {
        if (content != null) content.forEach { it.visitSpanRuns(visit) }
        else visit(spans, false)
    } else {
        val visitor = PresentationSpanVisitor(visit = visit)
        backlinks.forEach(visitor::backlink)
        if (content == null) visitor.spans(spans) else visitor.blocks(content)
    }
}
/** Applies to the complete semantic Section body, before References and Media. */
enum class BodyAdjoiningPolicy { Ordinary }

/** Independent body-slot metrics and paragraph direction; no hierarchy or source text. */
data class BodyTypography(val ownerFont: InlineFontSnapshot, val lineHeight: ContainerLineHeight? = null,
    val direction: BidiResolvedDirection? = null) {
    init {
        require(ownerFont.fontNormalized && ownerFont.fontScale != null &&
            ownerFont.fontScaleBasis in listOf(FontScaleBasis.NormalBody, FontScaleBasis.CssPx)) {
            "Body typography requires a normalized explicit size"
        }
    }
}

data class Entry(
    val title: String,
    val displayTitle: List<Span>,
    val kind: String,
    val language: String?,
    val languageCode: String,
    val sections: List<Section>,
    val references: List<Reference>,
    val preamble: List<Span> = emptyList(),
    val media: List<Media> = emptyList(),
    val redirect: Redirect? = null,
    val edition: String = "",
    val origin: WordHit? = null,
    val navigationKind: String = kind,
    val navigationLanguage: String? = language,
    // The body may come from a different immutable blob than the navigation origin.
    val contentDictionary: String? = null,
    val etymologySections: Set<Int> = emptySet(),
    val organization: PresentationOrganization? = null,
    val bodyAdjoining: BodyAdjoiningPolicy? = null,
    val bodyTypography: BodyTypography? = null,
    val referenceBatches: List<ReferenceBatchPlacement>? = null,
) {
    internal val rasterImages: List<RasterImageOccurrence> = rasterImageOccurrences(this)
    internal val inlineImages: List<InlineImage> = rasterImages.map { it.image }
    init {
        organization?.validate(sections)
        val occurrences = inlineImages
        if (occurrences.isNotEmpty()) {
            val byFile = media.groupBy { it.file }
            occurrences.groupBy { it.file }.values.forEach { group ->
                if (group.any { it.staticPoster != null }) require(group.map { it.staticPoster?.resourceIdentity }.distinct().size == 1) {
                    "Conflicting static poster resource identities"
                }
            }
            occurrences.forEach { image ->
                val matching = byFile[image.file]
                require(matching != null && matching.size == 1 && matching.single().kind == "image") { "Inline image asset is absent or ambiguous" }
            }
        }

    }
    val key: String = origin?.key ?: "$kind\u0000${language.orEmpty()}\u0000$title"
    // Constructed with the decoded entry on the import dispatcher.
    val readingRows: List<ReadingRow> = readingRows(sections, media, etymologySections, bodyAdjoining = bodyAdjoining,
        references = references, referenceBatches = referenceBatches)
    internal val legacyImageCaptions: Map<String, Set<String>> = legacyEmbeddedImageCaptions(this)
    internal val legacyImageFiles: Set<String> = legacyImageCaptions.keys
    internal val separateImageCaptionFiles: Set<String> = media.filter { distinctTypedImageCaption(this, it) }.map { it.file }.toSet()
    internal val abbreviations: List<Abbreviation> = entryAbbreviations(this)
    internal val textDetails: List<TextDetail> = entryTextDetails(this)
    fun clue(): String {
        // Media controls belong in the reader, not a saved word's textual clue.
        fun preview(block: Block) = block.cluePreview()
        val blocks = sections.asSequence().flatMap { it.blocks.asSequence() }
        val definition = blocks.filter { it.kind == "definition" }.map(::preview).firstOrNull { it.isNotBlank() }
        if (definition != null) {
            var end = minOf(definition.length, 420)
            if (end < definition.length && end > 0 && Character.isHighSurrogate(definition[end - 1]) &&
                Character.isLowSurrogate(definition[end])) end--
            return definition.take(end)
        }
        // A headword or language paragraph can precede useful unclassified body text.
        // Reuse rendered rows so an explicit companion heading is not repeated.
        // Prefer prose to standalone code examples, but keep code-only entry previews.
        val hasProse = readingRows.any { row ->
            val block = row.block
            block != null && block.kind !in setOf("blank", "rule", "preformatted") && preview(block).isNotBlank()
        }
        val fallback = StringBuilder(420)
        for (row in readingRows) {
            val block = row.block ?: continue
            if (block.kind in setOf("blank", "rule") || hasProse && block.kind == "preformatted") continue
            val separator = if (fallback.isEmpty()) "" else " · "
            val available = 420 - fallback.length - separator.length
            if (available <= 0) break
            val text = preview(block)
            if (text.isBlank()) continue
            var end = minOf(text.length, available)
            if (end < text.length && end > 0 && Character.isHighSurrogate(text[end - 1]) &&
                Character.isLowSurrogate(text[end])) end--
            if (end == 0) break
            fallback.append(separator).append(text, 0, end)
            if (end < text.length) break
        }
        // Table-authored meanings are a last resort: ordinary prose keeps its saved clue.
        if (fallback.isEmpty()) return tableClue().ifEmpty { "Definition unavailable." }
        return fallback.toString()
    }

    /** A study answer retains its first meaning and one immediate child, never a deepest leaf. */
    internal fun studyClue(): String {
        val fallback = clue()
        for (section in sections) {
            val index = section.blocks.indexOfFirst { it.kind == "definition" && it.cluePreview().isNotBlank() }
            if (index < 0) continue
            val parent = section.blocks[index]
            val parentDepth = parent.listPath.takeWhile { it == '#' }.length
            if (parentDepth == 0) return fallback
            var childDepth: Int? = null
            for (childIndex in index + 1 until section.blocks.size) {
                val block = section.blocks[childIndex]
                if (block.kind == "heading") break
                if (block.kind != "definition") continue
                val depth = block.listPath.takeWhile { it == '#' }.length
                if (depth <= parentDepth) break
                // Like compiled sense ownership, a skipped depth still attaches to
                // the nearest preceding ancestor. A blank child owns its descendants.
                if (childDepth != null && depth > childDepth) continue
                childDepth = depth
                val child = block.cluePreview()
                if (child.isBlank()) continue
                val text = parent.cluePreview() + " · " + child
                var end = minOf(text.length, 420)
                if (end < text.length && Character.isHighSurrogate(text[end - 1]) && Character.isLowSurrogate(text[end])) end--
                return text.take(end)
            }
            return fallback
        }
        return fallback
    }
}

private object TableClueComplete : RuntimeException(null, null, false, false)

private fun Entry.tableClue(): String {
    val result = StringBuilder(420)
    try {
        for (section in sections) for (block in section.blocks) block.table?.visitSpanRuns { spans, _ ->
            val text = textOf(spans.filterNot { span ->
                span.classes.split(previewClassWhitespace).any { it == "wikidict-media" || it == "audiotable" }
            })
            if (text.isNotBlank()) {
                val separator = if (result.isEmpty()) "" else " · "
                val available = 420 - result.length - separator.length
                if (available <= 0) throw TableClueComplete
                var end = minOf(text.length, available)
                if (end < text.length && end > 0 && Character.isHighSurrogate(text[end - 1]) &&
                    Character.isLowSurrogate(text[end])) end--
                if (end == 0) throw TableClueComplete
                result.append(separator).append(text, 0, end)
                // Stop the structural walk too; do not collect the remainder of a large table.
                if (end < text.length || result.length >= 417) throw TableClueComplete
            }
        }
    } catch (_: TableClueComplete) {
        // The existing visitor owns caption/cell/block precedence and recursion limits.
    }
    return result.toString()
}

private fun Block.cluePreview(): String {
    if (figure == null && flow == null) return textOf(spans.filterNot { span ->
        span.classes.split(previewClassWhitespace).any { it == "wikidict-media" || it == "audiotable" }
    })
    val runs = mutableListOf<String>()
    visitSpanRuns { spans, _ -> runs += textOf(spans.filterNot { span ->
        span.classes.split(previewClassWhitespace).any { it == "wikidict-media" || it == "audiotable" }
    }) }
    return runs.filter { it.isNotBlank() }.joinToString(" ")
}

/** Every serialized span sink participates in asset validation, even an empty
 * occurrence. Ruby descendants are validated even when graphical projection hides them. */
internal fun rasterImageOccurrences(entry: Entry): List<RasterImageOccurrence> = buildList {
    validateReferenceBatchPlacements(entry.sections, entry.references, entry.referenceBatches, entry.bodyAdjoining)
    val visitor = PresentationSpanVisitor { _, _ -> }
    visitor.validateAbsoluteContainers = true
    val citations = CitationNavigationValidation()
    visitor.onCitationMarker = citations::marker
    visitor.onBlock = { citations.reserve(it.anchor, it.anchorFallback) }
    visitor.visitFigureContent = { content ->
        if (content is FigureContent.Image) add(RasterImageOccurrence(checkNotNull(content.span.image), content.sizing))
    }
    var owners: MediaOwners? = null
    var byFile: Map<String, List<Media>>? = null
    var inReference = false
    visitor.onSpan = { span ->
        span.image?.let { add(RasterImageOccurrence(it)) }
        if (span.audioControl != null) {
            val currentFiles = byFile ?: entry.media.groupBy { it.file }.also { byFile = it }
            require(currentFiles[span.target.removePrefix("File:")]?.singleOrNull()?.kind == "audio") {
                "Audio control requires one exact audio catalog asset"
            }
        }
    }
    visitor.onTable = { table, tableDepth, contentDepth ->
        if (table.style?.isInline == true) {
            require(tableDepth == 1 && contentDepth == 0 && !inReference) { "Inline table requires an ordinary section context" }
            val currentOwners = owners ?: MediaOwners(entry.media).also { owners = it }
            val currentFiles = byFile ?: entry.media.groupBy { it.file }.also { byFile = it }
            table.rows.forEach { row -> row.forEach { cell ->
                cell.spans.forEach { span ->
                    val image = span.image
                    if (image != null) {
                        require(currentFiles[image.file]?.singleOrNull()?.kind == "image") {
                            "Inline table image must resolve to one image asset"
                        }
                        require(!span.hasClassToken("wikidict-media") || currentOwners.file(span) == image.file) {
                            "Inline table image marker does not match its image"
                        }
                    } else if (span.hasClassToken("wikidict-media")) {
                        val asset = currentOwners.file(span)?.let { currentFiles[it] }?.singleOrNull()
                        require(asset?.kind == "audio") { "Inline table media must resolve to one audio asset" }
                    }
                }
            } }
        }
    }
    visitor.bodyTypography(entry.bodyTypography)
    visitor.spans(entry.displayTitle); visitor.spans(entry.preamble)
    entry.sections.forEach { citations.reserve(it.anchor, it.anchorFallback); visitor.blocks(it.blocks) }
    inReference = true
    entry.references.forEach { reference ->
        citations.reference(reference)
        visitor.bodyTypography(reference.bodyTypography)
        reference.backlinks.forEach { citations.backlink(reference, it); visitor.backlink(it) }
        val blocks = reference.blocks
        if (blocks == null) visitor.spans(reference.spans) else visitor.blocks(blocks)
    }
    citations.finish()
    visitor.referenceBatches(entry.referenceBatches)
}

internal fun WordHit.isInstalled(installed: (String) -> Boolean): Boolean =
    installed(dictionary) && (contextDictionary == null || installed(contextDictionary))

internal fun Entry.isInstalled(installed: (String) -> Boolean): Boolean =
    origin?.isInstalled(installed) == true && contentDictionary?.let(installed) == true

private val previewClassWhitespace = Regex("\\s+")

fun textOf(spans: List<Span>): String =
    (if (spans.any { it.ruby != null || it.inlinePaddingGroup != null || it.inlineActionGroup != null || it.inlineBoxGroup != null || it.clippedAbsolute != null }) rubyFallbackText(spans) else spans.joinToString("") { it.text + it.trail })
        .replace(Regex("\\s+"), " ").trim()


/** Compiled annotations only: never parse label/source text into explanations. */
internal data class Abbreviation(val label: String, val explanation: String, val context: String)
internal enum class TextDetailKind { Abbreviation, MediaDescription, Advisory }
internal data class TextDetail(val kind: TextDetailKind, val label: String, val description: String, val context: String)
internal val Span.imageTooltip: String? get() = image?.tooltip ?: tooltip
internal fun entryAbbreviations(entry: Entry): List<Abbreviation> =
    entryAnnotations(entry, TextDetailKind.Abbreviation) { it.explanation }.map {
        Abbreviation(it.label, it.description, it.context)
    }
private fun entryTextDetails(entry: Entry): List<TextDetail> {
    val owners = MediaOwners(entry.media)
    val explanations = linkedSetOf<TextDetail>()
    val advisories = linkedSetOf<TextDetail>()
    visitEntryAnnotationRuns(entry) { spans, location ->
        val graphical = rubyGraphicalSpans(spans)
        val boxProjection = if (spans.hasNativeInlineGroups()) rubyGraphicalProjection(spans).takeIf { projection ->
            projection.ranges.any { it.role == RubyTextRole.BoxGroup }
        } else null
        var cachedContext: String? = null
        fun context(): String = cachedContext ?: run {
            val plain = textOf(spans)
            val points = plain.codePointCount(0, plain.length)
            val count = minOf(72, points)
            val excerpt = plain.substring(0, plain.offsetByCodePoints(0, count)) + if (count < points) "…" else ""
            (if (excerpt.isEmpty()) location else "$location: $excerpt").also { cachedContext = it }
        }
        fun collect(advisory: Boolean, result: MutableSet<TextDetail>) {
            var annotation: String? = null
            var kind = if (advisory) TextDetailKind.Advisory else TextDetailKind.Abbreviation
            var file: String? = null
            val label = StringBuilder()
            fun finish() {
                val description = annotation
                if (!description.isNullOrEmpty() && (label.isNotBlank() || kind != TextDetailKind.Abbreviation)) {
                    val base = context()
                    result.add(TextDetail(kind, label.toString(), description, if (file == null) base else "$base · $file"))
                }
                label.setLength(0)
            }
            fun append(span: Span, value: String?) {
                val owned = if (!advisory && !value.isNullOrEmpty()) owners.media(span) else null
                val nextKind = if (advisory) TextDetailKind.Advisory else if (owned != null) TextDetailKind.MediaDescription else TextDetailKind.Abbreviation
                val image = span.image
                val text = when {
                    advisory && image != null -> image.alt?.takeIf { it.isNotBlank() }.orEmpty()
                    span.kind == "line_break" -> span.trail
                    else -> span.text + span.trail
                }
                val nextFile = when {
                    advisory && image != null && text.isBlank() -> image.file
                    owned != null && text.isBlank() -> owned.file
                    else -> null
                }
                if (span.kind == "line_break") {
                    finish(); annotation = value; kind = nextKind; file = nextFile
                    label.append(text); finish(); annotation = null; file = null
                    return
                }
                if (value != annotation || nextKind != kind || nextFile != file) {
                    finish(); annotation = value; kind = nextKind; file = nextFile
                }
                if (!value.isNullOrEmpty()) label.append(text)
            }
            if (!advisory || boxProjection == null) {
                graphical.forEach { append(it, if (advisory) it.imageTooltip else it.explanation) }
            } else {
                var leaf = 0
                val titleOwners = ArrayList<RubyTextRange>()
                for (range in boxProjection.ranges) {
                    while (titleOwners.isNotEmpty() && !range.path.startsWith(titleOwners.last().path + "/"))
                        titleOwners.removeAt(titleOwners.lastIndex)
                    val source = range.span ?: continue
                    if (source.tooltip != null) titleOwners.add(range)
                    if (range.role == RubyTextRole.BoxGroup) {
                        source.tooltip?.takeIf { it.isNotEmpty() }?.let { title ->
                            // The original border/padding still owns its title when a child
                            // explicitly suppresses its own hover advice. Emit that owner once.
                            finish(); annotation = null; file = null
                            result.add(TextDetail(TextDetailKind.Advisory,
                                boxProjection.text.substring(range.start, range.end), title, context()))
                        }
                    } else if (range.role != RubyTextRole.Owner && range.role != RubyTextRole.PaddingGroup &&
                        range.role != RubyTextRole.ActionGroup && range.role != RubyTextRole.ClippedAbsolute) {
                        val projected = graphical[leaf++]
                        val nearestTitle = titleOwners.lastOrNull()
                        // A null child inherits its Box's title; the original owner record
                        // already carries it. Empty child/image titles remain explicit stops.
                        val value = if (source.tooltip == null && source.image?.tooltip == null &&
                            nearestTitle?.role == RubyTextRole.BoxGroup) null else projected.imageTooltip
                        append(projected, value)
                    }
                }
                check(leaf == graphical.size)
            }
            finish()
        }
        collect(false, explanations)
        collect(true, advisories)
        if (spans.any { it.clippedAbsolute != null }) {
            val projection = rubyGraphicalProjection(spans)
            for (range in projection.ranges.filter { it.role == RubyTextRole.ClippedAbsolute }) {
                val owner = checkNotNull(range.span)
                val label = projection.text.substring(range.start, range.end)
                if (owner.explanation.isNotEmpty() && label.isNotBlank())
                    explanations.add(TextDetail(TextDetailKind.Abbreviation, label, owner.explanation, context()))
                owner.tooltip?.takeIf { it.isNotEmpty() }?.let { tooltip ->
                    advisories.add(TextDetail(TextDetailKind.Advisory, label, tooltip, context()))
                }
            }
        }
    }
    return explanations.toList() + advisories.toList()
}
private fun entryAnnotations(entry: Entry, kind: TextDetailKind, valueOf: (Span) -> String): List<TextDetail> {
    val result = linkedSetOf<TextDetail>()
    fun include(spans: List<Span>, location: String) {
        val graphical = rubyGraphicalSpans(spans)
        var cachedContext: String? = null
        fun context(): String = cachedContext ?: run {
            val plain = textOf(spans)
            val points = plain.codePointCount(0, plain.length)
            val count = minOf(72, points)
            val excerpt = plain.substring(0, plain.offsetByCodePoints(0, count)) +
                if (count < points) "…" else ""
            (if (excerpt.isEmpty()) location else "$location: $excerpt").also { cachedContext = it }
        }
        var annotation = ""
        val label = StringBuilder()
        fun finish() {
            if (annotation.isNotEmpty() && label.isNotBlank())
                result.add(TextDetail(kind, label.toString(), annotation, context()))
            label.setLength(0)
        }
        for (span in graphical) {
            if (span.kind == "line_break") {
                finish()
                annotation = valueOf(span)
                label.append(span.trail)
                finish()
                annotation = ""
                continue
            }
            if (valueOf(span) != annotation) {
                finish()
                annotation = valueOf(span)
            }
            if (annotation.isNotEmpty()) label.append(span.text).append(span.trail)
        }
        finish()
        if (spans.any { it.clippedAbsolute != null }) {
            val projection = rubyGraphicalProjection(spans)
            for (range in projection.ranges.filter { it.role == RubyTextRole.ClippedAbsolute }) {
                val owner = checkNotNull(range.span)
                val label = projection.text.substring(range.start, range.end)
                val annotation = valueOf(owner)
                if (annotation.isNotEmpty() && label.isNotBlank())
                    result.add(TextDetail(kind, label, annotation, context()))
            }
        }
    }
    visitEntryAnnotationRuns(entry, ::include)
    return result.toList()
}

private fun visitEntryAnnotationRuns(entry: Entry, include: (List<Span>, String) -> Unit) {
    include(entry.displayTitle, "Title")
    include(entry.preamble, "About this entry")
    entry.sections.forEach { section ->
        val location = section.title.ifBlank { entry.title }
        lateinit var includeBlock: (Block, String) -> Unit
        fun includeTable(table: Table, tableLocation: String) {
            val rich = table.captionBlocks
            if (rich == null) include(table.caption, "$tableLocation · Table")
            else rich.forEach { includeBlock(it, "$tableLocation · Table") }
            table.rows.forEachIndexed { row, cells -> cells.forEachIndexed { column, cell ->
                val cellLocation = "$tableLocation · Table ${row + 1}, ${column + 1}"
                val blocks = cell.blocks
                if (blocks != null) blocks.forEachIndexed { index, block -> includeBlock(block, "$cellLocation · Block ${index + 1}") }
                else { include(cell.spans, cellLocation); cell.nestedTable?.let { includeTable(it, cellLocation) } }
            } }
        }
        lateinit var includeParts: (List<FlowPart>, String) -> Unit
        fun includeFigure(figure: Figure, at: String) {
            include(listOf(figure.content.span), at)
            val rich = figure.captionBlocks
            if (rich == null) include(figure.caption, at) else rich.forEach { includeBlock(it, at) }
        }
        includeParts = { parts, at -> parts.forEach { part -> when (part) {
            is FlowPart.Inline -> include(part.spans, at)
            is FlowPart.ImageFigure -> includeFigure(part.figure, at)
            is FlowPart.Scope -> includeParts(part.scope.parts, at)
        } } }
        includeBlock = { block, blockLocation -> when {
            block.container != null -> block.container.blocks.forEach { includeBlock(it, blockLocation) }
            block.figure != null -> includeFigure(block.figure, blockLocation)
            block.flow != null -> includeParts(block.flow, blockLocation)
            block.table != null -> includeTable(block.table, blockLocation)
            else -> include(block.spans, blockLocation)
        } }
        section.blocks.forEach { includeBlock(it, location) }
    }

    entry.references.forEach { reference ->
        val location = if (reference.kind == ReferenceKind.Note) "References ${reference.number}" else "References"
        reference.visitSpanRuns { spans, _ -> include(spans, location) }
    }
}
