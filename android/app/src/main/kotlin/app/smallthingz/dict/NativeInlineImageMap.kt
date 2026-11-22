package app.smallthingz.dict

/** One original image occurrence. Region/default actions do not become text or consume
 * extra logical positions; ordinary fallback links remain their own source occurrences. */
internal class NativeInlineImageMap(
    val span: Span, val path: String, val start: Int,
    originalWidth: Long?, originalHeight: Long?, layoutWidth: Double?, layoutHeight: Double?,
) {
    val map: ImageMap = checkNotNull(span.image?.map)
    val end: Int = Math.addExact(start, 1)
    val actions: List<ImageMapAction> = map.regions.map { it.action } + listOfNotNull(map.defaultAction)
    val hasDescription: Boolean get() = map.description != ImageMapDescription.None
    private val geometry = if (originalWidth == null || originalHeight == null || layoutWidth == null || layoutHeight == null)
        null else PreparedImageMap.prepare(map, originalWidth, originalHeight, layoutWidth, layoutHeight)
    val available: Boolean get() = geometry != null

    init { require(start >= 0 && path.isNotEmpty()) }

    fun activate(index: Int, openInternal: (EntryLink) -> Unit, openExternal: (String) -> Unit) {
        val action = actions[index]
        when (action.kind) {
            ImageMapActionKind.Internal -> openInternal(action.entryLink())
            ImageMapActionKind.External -> openExternal(action.target)
        }
    }

    /** First source region wins. Equal actions/labels never merge their occurrences.
     * No ready original dimensions means no spatial action, including the default. */
    fun accepts(index: Int, painted: ImageMapBounds, x: Double, y: Double): Boolean {
        require(index in actions.indices)
        val hit = geometry?.hit(painted, x, y) as? ImageMapHit.Action ?: return false
        return hit.regionIndex == index.takeIf { it < map.regions.size }
    }
}

/** Source map coordinates address the bitmap's content, excluding its authored border.
 * Ancestor scroll/clip wrappers keep this original coordinate plane via node translation. */
internal fun nativeInlineImageMapContentBounds(outer: ImageMapBounds, border: Double): ImageMapBounds? {
    if (!listOf(outer.left, outer.top, outer.width, outer.height, border).all(Double::isFinite) || border < 0.0)
        return null
    val result = ImageMapBounds(outer.left + border, outer.top + border,
        outer.width - 2.0 * border, outer.height - 2.0 * border)
    return result.takeIf { it.left.isFinite() && it.top.isFinite() && it.width > 0.0 && it.height > 0.0 &&
        (it.left + it.width).isFinite() && (it.top + it.height).isFinite() }
}
