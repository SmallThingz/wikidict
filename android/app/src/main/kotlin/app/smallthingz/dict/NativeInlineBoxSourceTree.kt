package app.smallthingz.dict

/** Source path, decoded owner identity and exact child index authenticate the parent.
 * Equal text ranges alone never establish ownership. */
internal data class InlineBoxOccurrence(val path: String, val owner: Span, val start: Int, val end: Int)

internal fun inlineBoxSourceParents(boxes: List<InlineBoxOccurrence>): List<Int>? {
    val byPath = boxes.indices.associateBy { boxes[it].path }
    if (byPath.size != boxes.size) return null
    val parents = MutableList(boxes.size) { -1 }
    val children = HashMap<Int, MutableList<Int>>()
    val segment = "/inlineBoxGroup/spans/"
    for ((index, box) in boxes.withIndex()) {
        if (box.start < 0 || box.end <= box.start || box.owner.inlineBoxGroup == null) return null
        val split = box.path.lastIndexOf(segment)
        if (split >= 0) {
            val suffix = box.path.substring(split + segment.length)
            val slot = suffix.toIntOrNull() ?: return null
            if (slot < 0 || suffix != slot.toString()) return null
            val parent = byPath[box.path.substring(0, split)] ?: return null
            val source = boxes[parent]
            if (source.owner.inlineBoxGroup?.spans?.getOrNull(slot) !== box.owner ||
                box.start < source.start || box.end > source.end) return null
            parents[index] = parent
        }
        children.getOrPut(parents[index]) { mutableListOf() }.add(index)
    }
    for (box in boxes) {
        for ((slot, child) in checkNotNull(box.owner.inlineBoxGroup).spans.withIndex()) {
            if (child.inlineBoxGroup != null && byPath[box.path + segment + slot] == null) return null
        }
    }
    for ((parent, siblings) in children) {
        val ordered = if (parent < 0) siblings.sortedBy { boxes[it].start }
            else siblings.sortedBy { boxes[it].path.substringAfterLast('/').toInt() }
        if (ordered.zipWithNext().any { (a, b) -> boxes[a].end > boxes[b].start }) return null
    }
    // Depth is bound by the wire decoder. Use the same limit here for in-memory fixtures.
    for (index in boxes.indices) {
        var depth = 0
        var parent = parents[index]
        while (parent >= 0) {
            if (++depth >= MaxContentDepth) return null
            parent = parents[parent]
        }
    }
    return parents
}

/** Static source-owned paint envelopes: the text engine still owns all child glyphs and actions. */
internal fun nativeInlineSimplePaintTree(owner: Span, depth: Int = 0): Boolean {
    if (depth >= MaxContentDepth || owner.usesInlineDirectionIsolate() || owner.image != null ||
        owner.ruby != null || owner.clippedAbsolute != null || owner.audioControl != null ||
        owner.inlinePaddingGroup != null || owner.inlineActionGroup != null || owner.citationMarker != null ||
        owner.isQualifiedCitationBacklink || owner.superscript || owner.subscript) return false
    val style = owner.inlineStyle
    if (style?.baselineShift != null || style?.lineHeight != null || style?.decoration != null ||
        style?.wrap != null) return false
    val box = owner.inlineBoxGroup ?: return owner.kind == "text" || owner.kind == "link"
    if (owner.kind != "text" ||
        box.atomicLayout != null || box.atomicAutoLayout != null || box.intrinsicLinesLayout != null ||
        box.overlays.isNotEmpty() || box.radius != null || box.verticalAlign != null ||
        box.padding.top.value != 0f || box.padding.bottom.value != 0f) return false
    val none = InlineBoxBorderEdge.None
    if (box.border.left != none || box.border.right != none || box.border.top != none ||
        box.border.bottom != none && box.border.bottom !is InlineBoxBorderEdge.Dotted) return false
    return box.spans.all { nativeInlineSimplePaintTree(it, depth + 1) }
}
