package app.smallthingz.dict

/** Visibility is a projection of original addresses, never a filtered source tree. */
internal fun nativeDisclosureHiddenChild(owner: Container, expanded: Boolean): Int? {
    val policy = owner.disclosure ?: return null
    if (policy.contentIndex < 0L || policy.contentIndex >= owner.blocks.size.toLong() ||
        owner.blocks[policy.contentIndex.toInt()].container == null)
        throw UnsupportedFloatLayout("Disclosure requires its original immediate child Container")
    return if (expanded) null else policy.contentIndex.toInt()
}

internal fun nativeDisclosureFlowItems(blocks: List<Block>, row: Boolean, hiddenChild: Int?): List<ContainerFlowItem> {
    val original = if (row) containerFlowItems(blocks) else blocks.indices.map { ContainerFlowItem.Block(it) }
    return if (hiddenChild == null) original else original.filterNot {
        it is ContainerFlowItem.Block && it.index == hiddenChild
    }
}

/** Fit against the real owner's content width; rounding belongs only to View allocation. */
internal fun nativeDisclosureWidth(containingWidth: Float, intrinsic: ContainerWidths): Float {
    if (!containingWidth.isFinite() || containingWidth < 0f)
        throw UnsupportedFloatLayout("Disclosure containing width is unavailable")
    return minOf(maxOf(containingWidth, intrinsic.minimum), intrinsic.maximum)
}

/** A generated control inherits the actual full declaring Cell font, unlike ordinary child
 * defaults. This is an already resolved native projection, not stored W admission: a valid
 * Cell snapshot may have normalized=false and must never be normalized or scaled again. */
internal fun nativeDisclosureTextFormat(context: ContainerTextContext,
    format: NativeContainerTextFormat): NativeContainerTextFormat {
    if (format.ownerFont != null) return format // A nearer independently resolved W owner wins.
    val cell = context.cellText ?: return format
    if (cell.ownerFontInvalidated) throw UnsupportedFloatLayout(NativeCellOwnerFontChanged)
    val owner = cell.ownerFont ?: return format
    val style = owner.style ?: throw UnsupportedFloatLayout(NativeCellOwnerFontUnavailable)
    val pixels = cell.fontPixels ?: throw UnsupportedFloatLayout(NativeCellOwnerFontUnavailable)
    val family = owner.snapshot.fontFamily ?: throw UnsupportedFloatLayout(NativeCellOwnerFontUnavailable)
    if (nativeTableOwnerLanguageTag(owner.snapshot.language) == null)
        throw UnsupportedFloatLayout(NativeCellOwnerFontUnavailable)
    return format.copy(style = format.style.merge(style), sourceFamily = family,
        ownerFont = owner.copy(kind = NativeDeclaringFontKind.Container, fontPixels = pixels))
}
