package app.smallthingz.dict

/** Compiled LI/list/wrapper ownership, never reconstructed from a note's text. */
data class ReferenceItemLayout(val box: ContainerStyle, val marker: ReferenceListMarker,
    val markerForeground: FigureColor, val backlinkPrefix: ReferenceBacklinkPrefix,
    val targetBackground: ContainerColor? = null)
enum class ReferenceListMarker { DecimalOutside }
enum class ReferenceBacklinkPrefix { SingleSpace }
data class ReferenceBatchLayout(val wrapper: ContainerStyle, val list: ContainerStyle,
    val items: List<ReferenceItemLayout>)

internal fun validReferenceLayoutStyle(value: ContainerStyle): Boolean =
    value.margins != null && value.padding != null && value.border != null && value.background != null &&
        value.ownerFont?.fontNormalized == true && value.layout == ContainerLayout.Flow &&
        value.clear == FigureClear.None && value.overflow == ContainerOverflow.Visible &&
        value.width == null && value.floatSide == null && value.maxWidth == null &&
        value.alignItems == null && value.flexItem == null && value.textAlign == null &&
        value.screenMaxWidth == null && value.height == null && value.columns == null &&
        value.positioning == null && value.minHeight == null && value.marginValues == null &&
        value.absolutePosition == null && value.textWrap == null && value.absoluteStatic == null

internal fun referenceLayoutBodyStartsText(spans: List<Span>): Boolean {
    val first = spans.firstOrNull() ?: return false
    return first.kind in setOf("text", "link", "external_link") && first.text.isNotEmpty() &&
        first.text.first() !in " \t\r\n\u000c" && first.audioControl == null && first.image == null &&
        first.ruby == null && first.inlinePaddingGroup == null && first.inlineActionGroup == null &&
        first.inlineBoxGroup == null && first.clippedAbsolute == null
}

internal fun validateReferenceBatchLayout(layout: ReferenceBatchLayout, indices: List<Int>, references: List<Reference>) {
    require(validReferenceLayoutStyle(layout.wrapper) && validReferenceLayoutStyle(layout.list) &&
        indices.isNotEmpty() && layout.items.size == indices.size && layout.items.size <= (1 shl 20)) {
        "Incomplete compiled reference layout"
    }
    layout.items.zip(indices).forEach { (item, index) ->
        val reference = references.getOrNull(index) ?: error("Reference layout index is absent")
        val typography = reference.bodyTypography ?: error("Reference layout requires its original body typography")
        require(validReferenceLayoutStyle(item.box) && item.markerForeground is FigureColor.Rgb &&
            reference.kind == ReferenceKind.Note && reference.groupNumber != null && reference.groupNumber > 0 &&
            reference.blocks == null && referenceLayoutBodyStartsText(reference.spans) &&
            typography.direction != null && typography.ownerFont == item.box.ownerFont &&
            typography.lineHeight == item.box.lineHeight && reference.backlinks.size == 1) {
            "Reference layout does not match its original note owner"
        }
    }
}

/** Rendering projection only. Original references, indices and qualified backlink objects survive. */
internal data class ReferenceLayoutParagraph(val referenceIndex: Int, val reference: Reference,
    val item: ReferenceItemLayout) {
    val marker: String get() = "${reference.groupNumber}."
    val backlink: ReferenceBacklink get() = reference.backlinks.single()
    val spans: List<Span> get() = listOf(backlink.span,
        inlineFontSnapshotSpan(checkNotNull(item.box.ownerFont))) + reference.spans
}
internal data class ReferenceLayoutProjection(val blocks: List<Block>,
    val paragraphs: Map<String, ReferenceLayoutParagraph>)

internal data class ReferenceMarkerAnchor(val x: Float, val baseline: Float, val rightAligned: Boolean,
    val left: Float, val right: Float)
/** Outside markers consume no LI content width; their real font advance stays in overflow bounds. */
internal fun referenceMarkerAnchor(left: Float, right: Float, advance: Float, baseline: Float,
    rtl: Boolean): ReferenceMarkerAnchor {
    require(listOf(left, right, advance, baseline).all { it.isFinite() } && right >= left && advance >= 0f)
    return if (rtl) ReferenceMarkerAnchor(right, baseline, false, right, right + advance)
        else ReferenceMarkerAnchor(left, baseline, true, left - advance, left)
}

internal fun referenceLayoutProjection(batch: ReferenceBatchPlacement, references: List<Reference>,
    path: String, targetReferenceIndex: Int? = null, rootBlockPath: String = "$path/block-0"): ReferenceLayoutProjection {
    val layout = batch.layout ?: error("Reference layout owner is absent")
    validateReferenceBatchLayout(layout, batch.referenceIndices, references)
    val paragraphs = linkedMapOf<String, ReferenceLayoutParagraph>()
    val children = batch.referenceIndices.mapIndexed { position, index ->
        val paragraph = ReferenceLayoutParagraph(index, references[index], layout.items[position])
        // Paths follow the existing Container adapter, not a second tree walker.
        paragraphs["$rootBlockPath/container/block-0/container/block-$position/container/block-0"] = paragraph
        val box = if (targetReferenceIndex == index && paragraph.item.targetBackground != null)
            paragraph.item.box.copy(background = paragraph.item.targetBackground) else paragraph.item.box
        Block("container", depth = 0, spans = emptyList(), container = Container(listOf(Block("paragraph", depth = 0, spans = paragraph.reference.spans)), box))
    }
    return ReferenceLayoutProjection(listOf(Block("container", depth = 0, spans = emptyList(), container = Container(
        listOf(Block("container", depth = 0, spans = emptyList(), container = Container(children, layout.list))), layout.wrapper))), paragraphs)
}
