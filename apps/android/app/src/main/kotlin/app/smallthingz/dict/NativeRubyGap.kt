package app.smallthingz.dict

/** Transient visual effects; sourceOffset addresses the unchanged raw gap's UTF-16 string. */
internal data class NativeRubyGapCollapse(
    val text: String,
    val sourceOffset: Int?,
    val removePreviousSpace: Boolean,
    val removeFollowingSpace: Boolean,
)

/** CSS normal/nowrap only. The native UA choice transforms every surviving LF to SPACE;
 * it does not infer a language/script-dependent removal rule. Retained CR behaves as SPACE.
 * The caller supplies structural and actual line-edge context, applies neighbor effects only
 * to eligible same-level collapsible spaces, and retains the original source and range map.
 * Recompute these effects after reflow; they are not mutations of neighboring source text. */
internal fun nativeRubyGapCollapse(
    raw: String,
    structurallyDiscarded: Boolean,
    previousCollapsibleSpace: Boolean,
    followingCollapsibleSpace: Boolean,
    trimAtLineEdge: Boolean,
): NativeRubyGapCollapse {
    if ('\u000c' in raw) throw UnsupportedFloatLayout("Ruby gap form feed is unavailable")
    require(raw.all { it == ' ' || it == '\t' || it == '\n' || it == '\r' }) {
        "Ruby gap contains non-gap text"
    }
    if (raw.isEmpty() || structurallyDiscarded) return NativeRubyGapCollapse("", null, false, false)

    // Spaces around segment breaks disappear before LF becomes the retained space.
    // Otherwise the first preceding space owns the chain, or the first raw character does.
    val firstLf = raw.indexOf('\n')
    val sourceOffset = when {
        firstLf >= 0 -> firstLf
        previousCollapsibleSpace -> null
        else -> 0
    }
    val retained = sourceOffset != null && !trimAtLineEdge
    return NativeRubyGapCollapse(
        text = if (retained) " " else "",
        sourceOffset = if (retained) sourceOffset else null,
        removePreviousSpace = firstLf >= 0 && previousCollapsibleSpace,
        removeFollowingSpace = followingCollapsibleSpace,
    )
}
