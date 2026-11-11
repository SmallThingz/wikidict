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
internal data class MissingLinkActionIdentity(val owner: Any, val target: MissingLinkTarget)
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
internal class NativeMissingLinkPaint(val policy: MissingLinkPaint, val dark: Boolean, val visited: Boolean,
    private val childUnderline: Boolean = false, val actionIdentity: MissingLinkActionIdentity? = null) {
    var hovered by mutableStateOf(false)
    var active by mutableStateOf(false)
    fun appearance(): MissingLinkAppearance = missingLinkAppearance(policy, dark, visited, hovered, active).let {
        it.copy(underline = childUnderline || it.underline)
    }
}
