package app.smallthingz.dict

import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf

internal data class MissingLinkTarget(val edition: String, val kind: String, val target: String, val fragment: String?)
internal fun missingLinkTarget(span: Span, edition: String, documentTitle: String = ""): MissingLinkTarget = if (span.kind == "link") {
    val link = span.entryLink()
    MissingLinkTarget(edition, span.kind, link.title.ifEmpty { documentTitle }, link.fragment.takeIf { link.hasFragment })
} else MissingLinkTarget("", span.kind, span.target, null)

/** Only activations observed by this reader session; no browser-history or persisted-history claim. */
internal class MissingLinkVisits {
    private val targets = mutableStateMapOf<MissingLinkTarget, Unit>()
    fun contains(target: MissingLinkTarget): Boolean = targets.containsKey(target)
    fun record(target: MissingLinkTarget) { targets[target] = Unit }
    fun clear() = targets.clear()
}
internal val LocalMissingLinkVisits = staticCompositionLocalOf<MissingLinkVisits?> { null }
internal val LocalMissingLinkDocument = staticCompositionLocalOf { "" }
/** Separate from session visits: a held key belongs to one rendered document/visit. */
internal val LocalMissingLinkOwner = staticCompositionLocalOf<Any?> { null }
internal data class MissingLinkActionIdentity(val owner: Any, val target: MissingLinkTarget,
    val occurrence: Any? = null)
internal data class NativeLinkOccurrenceIdentity(val owner: Any, val spanIndex: Int,
    val start: Int, val end: Int, val span: Span)
internal data class FigureCaptionLinkScope(val policy: FigureLinkPaint, val visits: MissingLinkVisits,
    val documentTitle: String, val owner: Any, val density: Float, val bodyPixels: Float)
internal val LocalFigureCaptionLinkScope = staticCompositionLocalOf<FigureCaptionLinkScope?> { null }
/** A declared unavailable projection keeps body/actions without recursively retrying native paint. */
internal val LocalOrdinaryLinkPaintNative = staticCompositionLocalOf { true }
internal const val NativeOrdinaryLinkPaintUnavailable = "Source link interaction paint is unavailable for this action."
internal fun ordinaryLinkPaintUnavailable(spans: List<Span>, edition: String? = null): String? {
    if (spans.none { it.linkPaint != null }) return null
    val supported = nativeCaptionLinkRanges(spans).map { it.index }.toSet()
    return NativeOrdinaryLinkPaintUnavailable.takeIf {
        spans.withIndex().any { (index, span) -> span.linkPaint != null &&
            if (span.image != null) !nativeImageLinkPaintSupported(span, edition)
            else span.text.isEmpty() && span.trail.isEmpty() || index !in supported }
    }
}
/** Replaced images keep their own action node; they never enter text-link paint ranges.
 * Preparation supplies the edition to require a usable source action, not a reader Details action. */
internal fun nativeImageLinkPaintSupported(span: Span, edition: String? = null): Boolean {
    val image = span.image ?: return false
    return span.text.isEmpty() && span.trail.isEmpty() && image.alt.isNullOrEmpty() &&
        image.map == null && image.staticPoster == null &&
        (span.hasInternalAction() || externalLinkUrl(span) != null) &&
        (edition == null || span.kind != "link" || !span.target.startsWith("File:") ||
            inlineImageLinkUrl(span, edition) != null)
}
internal fun tableHasOrdinaryLinkPaint(table: Table): Boolean {
    var found = false
    table.visitSpans { spans -> if (spans.any { it.linkPaint != null }) found = true }
    return found
}
internal data class NativeCaptionLinkRange(val index: Int, val span: Span, val start: Int, val end: Int)
internal fun nativeCaptionLinkRanges(spans: List<Span>): List<NativeCaptionLinkRange> = buildList {
    var offset = 0
    spans.forEachIndexed { index, span ->
        val start = offset
        if (span.usesInlineDirectionIsolate()) offset++
        offset += if (span.image != null || span.kind == "line_break") 1 else span.text.length
        offset += span.trail.length
        if (span.usesInlineDirectionIsolate()) offset++
        if (offset > start && span.image == null && (span.hasInternalAction() || externalLinkUrl(span) != null))
            add(NativeCaptionLinkRange(index, span, start, offset))
    }
}
/** A semantic name never replaces the original rendered text or compiled action. */
internal fun nativeInternalLinkAccessibilityLabel(label: CharSequence, source: Span?): CharSequence {
    // Native direction isolates are invisible ownership controls, not a spoken label.
    val named = label.any { !it.isWhitespace() && it !in '\u2066'..'\u2069' }
    if (named || source?.hasInternalAction() != true) return label
    val action = source.entryLink()
    return action.target + action.targetFragment?.takeIf { it.isNotEmpty() }?.let { "#$it" }.orEmpty()
}

internal fun nativeInternalLinkAccessibilitySource(sources: List<NativeCaptionLinkRange>,
    start: Int, end: Int, target: String): Span? = sources.singleOrNull {
    it.start == start && it.end == end && it.span.hasInternalAction() && it.span.target == target
}?.span

internal data class NativeLinkKeyPress(val nodeId: Int, val keyCode: Int,
    val identity: MissingLinkActionIdentity?, val action: () -> Unit) {
    fun matches(node: FloatInteractionNode): Boolean = node.id == nodeId && node.onClick != null &&
        (if (identity != null) node.missingLinkPaint?.actionIdentity == identity else node.onClick === action)
}

internal data class MissingLinkAppearance(val color: Int, val underline: Boolean)
internal fun missingLinkAppearance(policy: MissingLinkPaint, dark: Boolean, visited: Boolean,
    hovered: Boolean, active: Boolean): MissingLinkAppearance {
    val index = (if (visited) 3 else 0) + if (active) 2 else if (hovered) 1 else 0
    val palette = when (policy) {
        MissingLinkPaint.VectorNewLinkV1 -> if (dark) intArrayOf(0xfffd7865.toInt(), 0xfffea898.toInt(),
            0xffffc8bd.toInt(), 0xffc99391.toInt(), 0xffdcb5b3.toInt(), 0xffe8cecd.toInt())
        else intArrayOf(0xffbf3c2c.toInt(), 0xff9f3526.toInt(), 0xff612419.toInt(),
            0xff9f5555.toInt(), 0xff854848.toInt(), 0xff512e2e.toInt())
    }
    return MissingLinkAppearance(palette[index], hovered || active)
}

/** Draw-only state shared by the existing native text span and its translated interaction node. */
internal class NativeMissingLinkPaint private constructor(private val legacyPolicy: MissingLinkPaint?,
    val fixedPolicy: FigureLinkPaint?, val dark: Boolean, val visited: Boolean,
    private val childUnderline: Boolean, val actionIdentity: MissingLinkActionIdentity?,
    val ordinaryPolicy: LinkPaint? = null) {
    constructor(policy: MissingLinkPaint, dark: Boolean, visited: Boolean,
        childUnderline: Boolean = false, actionIdentity: MissingLinkActionIdentity? = null) :
        this(policy, null, dark, visited, childUnderline, actionIdentity)
    constructor(policy: FigureLinkPaint, visited: Boolean,
        childUnderline: Boolean = false, actionIdentity: MissingLinkActionIdentity? = null) :
        this(null, policy, false, visited, childUnderline, actionIdentity)
    constructor(policy: LinkPaint, visited: Boolean, actionIdentity: MissingLinkActionIdentity? = null) :
        this(null, null, false, visited, false, actionIdentity, policy)
    /** This explicit source occurrence uses focus-visible modality; legacy owner policies stay unchanged. */
    val sourceSpanPaint: Boolean get() =
        (actionIdentity?.occurrence as? NativeLinkOccurrenceIdentity)?.span?.linkPaint != null
    var hovered by mutableStateOf(false)
    var active by mutableStateOf(false)
    var focused by mutableStateOf(false)
    fun appearance(): MissingLinkAppearance {
        val ordinary = ordinaryPolicy
        val fixed = fixedPolicy
        val value = when {
            ordinary != null -> ordinary.state(visited, hovered, active).let {
                MissingLinkAppearance(0xff000000.toInt() or it.foreground.substring(1).toInt(16),
                    it.underline || focused && ordinary.underlineOnFocus)
            }
            fixed != null -> fixed.state(visited, hovered, active).let {
                MissingLinkAppearance(0xff000000.toInt() or it.foreground.substring(1).toInt(16),
                    it.underline || focused && fixed.underlineOnFocus)
            }
            else -> missingLinkAppearance(checkNotNull(legacyPolicy), dark, visited, hovered, active)
        }
        return value.copy(underline = childUnderline || value.underline)
    }
}
