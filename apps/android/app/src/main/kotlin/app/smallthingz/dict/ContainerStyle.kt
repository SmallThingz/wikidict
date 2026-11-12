package app.smallthingz.dict

sealed interface ContainerWidth {
    data object Auto : ContainerWidth
    data class Length(val value: StyleWidth) : ContainerWidth
    data object FitContent : ContainerWidth
}
sealed interface ContainerMaxWidth {
    data object None : ContainerMaxWidth
    data class Length(val value: StyleWidth) : ContainerMaxWidth
}
enum class ContainerBoxSizing { ContentBox, BorderBox }
enum class ContainerLayout { Flow, FlexRow }
enum class ContainerAlignItems { Stretch, Start, Center, End }
enum class ContainerFlexItem { None }
enum class ContainerOverflow { Visible, Auto }
enum class ContainerPositioning { RelativeAuto }
sealed interface ContainerColor {
    data object Transparent : ContainerColor
    data class Rgb(val value: String) : ContainerColor {
        init { require(Regex("#[0-9a-f]{6}").matches(value)) { "Invalid container RGB" } }
    }
    data class LightDark(val light: String, val dark: String) : ContainerColor {
        init { require(listOf(light, dark).all { Regex("#[0-9a-f]{6}").matches(it) }) { "Invalid container theme RGB" } }
    }
}
sealed interface ContainerBorder {
    data object None : ContainerBorder
    data class Solid(val width: StyleLength, val color: ContainerColor) : ContainerBorder
    data class Edges(val top: ContainerBorderEdge, val right: ContainerBorderEdge,
        val bottom: ContainerBorderEdge, val left: ContainerBorderEdge) : ContainerBorder
}
sealed interface ContainerBorderEdge {
    data object None : ContainerBorderEdge
    data object Hidden : ContainerBorderEdge
    data class Solid(val width: StyleLength, val color: ContainerColor) : ContainerBorderEdge
    data class Dotted(val width: StyleLength, val color: ContainerColor) : ContainerBorderEdge
}
internal fun ContainerBorder?.physicalEdges(): ContainerBorder.Edges = when (this) {
    null, ContainerBorder.None -> ContainerBorder.Edges(ContainerBorderEdge.None, ContainerBorderEdge.None,
        ContainerBorderEdge.None, ContainerBorderEdge.None)
    is ContainerBorder.Solid -> ContainerBorderEdge.Solid(width, color).let { ContainerBorder.Edges(it, it, it, it) }
    is ContainerBorder.Edges -> this
}
internal val ContainerBorderEdge.usedWidth: StyleLength? get() = when (this) {
    ContainerBorderEdge.None, ContainerBorderEdge.Hidden -> null
    is ContainerBorderEdge.Solid -> width
    is ContainerBorderEdge.Dotted -> width
}
sealed interface ContainerLineHeight {
    data object Normal : ContainerLineHeight
    data class Multiplier(val value: Float) : ContainerLineHeight {
        init { require(value.isFinite() && value >= 0f) { "Invalid inherited container line height" } }
    }
    data class Length(val value: StyleLength) : ContainerLineHeight
}
enum class ContainerFloatOverride { None, Left, Right }
/** Only Container margins accept signed lengths; ordinary StyleLength stays nonnegative. */
sealed interface ContainerMarginLength { val unit: StyleLengthUnit; val value: Float }
data class SignedContainerMargin(override val unit: StyleLengthUnit, override val value: Float) : ContainerMarginLength {
    init { require(value.isFinite()) { "Invalid container margin" } }
}
sealed interface ContainerMarginEdges {
    val top: ContainerMarginLength
    val right: ContainerMarginLength
    val bottom: ContainerMarginLength
    val left: ContainerMarginLength
}
data class SignedContainerEdges(override val top: ContainerMarginLength, override val right: ContainerMarginLength,
    override val bottom: ContainerMarginLength, override val left: ContainerMarginLength) : ContainerMarginEdges
sealed interface ContainerMargin {
    data object Auto : ContainerMargin
    data class Length(val value: ContainerMarginLength) : ContainerMargin
}
data class ContainerMargins(val top: ContainerMargin, val right: ContainerMargin,
    val bottom: ContainerMargin, val left: ContainerMargin)
data class ContainerScreenMaxWidth(val maxWidthPx: Long, val width: ContainerWidth? = null,
    val maxWidth: ContainerMaxWidth? = null, val boxSizing: ContainerBoxSizing? = null,
    val lineHeight: ContainerLineHeight? = null, val floatSide: ContainerFloatOverride? = null,
    val margins: ContainerMargins? = null, val clear: FigureClear? = null,
    val followingRules: List<ContainerScreenMaxWidth> = emptyList()) {
    init {
        require(maxWidthPx in 0L..0xffff_ffffL) { "Invalid viewport threshold" }
        require(width != null || maxWidth != null || boxSizing != null || lineHeight != null ||
            floatSide != null || margins != null || clear != null) { "Empty viewport override" }
        require(followingRules.size < 16) { "Too many viewport overrides" }
        var previous = maxWidthPx
        followingRules.forEach { rule ->
            require(rule.followingRules.isEmpty() && rule.maxWidthPx < previous) {
                "Viewport overrides must be flat and strictly descending"
            }
            previous = rule.maxWidthPx
        }
    }
}
data class ContainerColumns(val count: Int, val gap: StyleLength) {
    init { require(count in 1..65535) { "Invalid container column count" } }
}
data class ContainerStyle(val margins: ContainerMarginEdges? = null, val padding: StyleEdges? = null,
    val width: ContainerWidth? = null, val floatSide: TableFloatSide? = null, val clear: FigureClear? = null,
    val maxWidth: ContainerMaxWidth? = null, val boxSizing: ContainerBoxSizing? = null,
    val layout: ContainerLayout? = null, val alignItems: ContainerAlignItems? = null,
    val flexItem: ContainerFlexItem? = null, val background: ContainerColor? = null,
    val border: ContainerBorder? = null, val lineHeight: ContainerLineHeight? = null,
    val textAlign: CellTextAlign? = null, val screenMaxWidth: ContainerScreenMaxWidth? = null,
    val overflow: ContainerOverflow? = null, val ownerFontScale: Float? = null,
    val height: StyleLength? = null, val columns: ContainerColumns? = null,
    val positioning: ContainerPositioning? = null, val minHeight: StyleLength? = null,
    val marginValues: ContainerMargins? = null) {
    init {
        require(margins == null || marginValues == null) { "Conflicting container margin representations" }
        require(alignItems == null || layout == ContainerLayout.FlexRow) { "Alignment requires a flex row" }
        require(ownerFontScale == null || ownerFontScale.isFinite() && ownerFontScale >= 0f) {
            "Invalid container owner font scale"
        }
    }

    internal fun textContext(inherited: ContainerTextContext): ContainerTextContext =
        ContainerTextContext(ownerFontScale ?: inherited.ownerFontScale, lineHeight ?: inherited.lineHeight,
            inherited.cellText?.copy(fontPixels = if (ownerFontScale == null) inherited.cellText.fontPixels else null,
                lineHeight = if (lineHeight == null) inherited.cellText.lineHeight else null))

    /** Call with the reader viewport, never a nested cell's or container's width. */
    internal fun atViewport(cssWidth: Float): ContainerViewportStyle = atViewport(cssWidth.toDouble())
    internal fun atViewport(cssWidth: Double): ContainerViewportStyle {
        require(cssWidth.isFinite() && cssWidth >= 0f)
        var box = copy(margins = null, marginValues = null, screenMaxWidth = null)
        var resolvedMargins = marginValues ?: margins?.let { ContainerMargins(ContainerMargin.Length(it.top),
            ContainerMargin.Length(it.right), ContainerMargin.Length(it.bottom), ContainerMargin.Length(it.left)) }
        val rules = screenMaxWidth?.let { listOf(it) + it.followingRules }.orEmpty()
        for (rule in rules) if (cssWidth <= rule.maxWidthPx.toDouble()) {
            val resolvedFloat = when (rule.floatSide) {
                null -> box.floatSide
                ContainerFloatOverride.None -> null
                ContainerFloatOverride.Left -> TableFloatSide.Left
                ContainerFloatOverride.Right -> TableFloatSide.Right
            }
            box = box.copy(width = rule.width ?: box.width, maxWidth = rule.maxWidth ?: box.maxWidth,
                boxSizing = rule.boxSizing ?: box.boxSizing, lineHeight = rule.lineHeight ?: box.lineHeight,
                floatSide = resolvedFloat, clear = rule.clear ?: box.clear)
            resolvedMargins = rule.margins ?: resolvedMargins
        }
        return ContainerViewportStyle(box, resolvedMargins)
    }
}
/** Computed font inheritance is independent of descendants and already-normalized box lengths.
 * Holding this context does not create a line box in an empty Container. */
internal data class ContainerTextContext(val ownerFontScale: Float = 1f,
    val lineHeight: ContainerLineHeight = ContainerLineHeight.Normal,
    val cellText: NativeCellTextState? = null) {
    init { require(ownerFontScale.isFinite() && ownerFontScale >= 0f) }
}

/** Rendering state, not a new wire field. Auto margins survive until used box geometry is known. */
internal data class ContainerViewportStyle(val box: ContainerStyle, val margins: ContainerMargins?) {
    init { require(box.screenMaxWidth == null && box.margins == null && box.marginValues == null) }
    val ownsFormattingContext: Boolean get() = box.floatSide != null ||
        box.layout == ContainerLayout.FlexRow || box.overflow == ContainerOverflow.Auto || box.columns != null
}
data class Container(val blocks: List<Block>, val style: ContainerStyle = ContainerStyle()) {
    init { require(supportedContainerShape(this, 1)) { "Unsupported container heading or depth" } }
}
private fun ContainerMarginEdges.hasVerticalMargin(): Boolean = top.value != 0f || bottom.value != 0f
private fun ContainerMargin.isNonzero(): Boolean = this is ContainerMargin.Length && value.value != 0f
private fun ContainerStyle.ownMarginsSupported(): Boolean {
    if (marginValues != null) return false // This representation requires M, including numeric-only values.
    var vertical = margins?.hasVerticalMargin() == true
    var floating = floatSide != null
    if (!floating && vertical) return false
    val screen = screenMaxWidth ?: return true
    for (rule in listOf(screen) + screen.followingRules) {
        floating = rule.floatSide?.let { it != ContainerFloatOverride.None } ?: floating
        vertical = rule.margins?.let { it.top.isNonzero() || it.bottom.isNonzero() } ?: vertical
        if (!floating && vertical) return false
    }
    return true
}
internal fun legacyContainerMarginsSupported(value: Container, depth: Int = 1): Boolean {
    if (depth > MaxContentDepth || value.blocks.size > (1 shl 20)) return false
    if (!value.style.ownMarginsSupported()) return false
    return value.blocks.all { block -> block.kind != "heading" && block.style?.margins?.hasVerticalMargin() != true &&
        (block.container == null || legacyContainerMarginsSupported(block.container, depth + 1)) }
}

private fun supportedContainerShape(value: Container, depth: Int): Boolean {
    if (depth > MaxContentDepth || value.blocks.size > (1 shl 20)) return false
    return value.blocks.all { block -> block.kind != "heading" &&
        (block.container == null || supportedContainerShape(block.container, depth + 1)) }
}

/** Real root plus child suffix. The authored tree remains the rendering owner. */
internal fun resolveBlockPath(blocks: List<Block>, root: Int, suffix: List<Int>): Block {
    require(suffix.size <= MaxContentDepth) { "Container address is too deep" }
    var block = blocks.getOrNull(root) ?: error("Invalid root block address")
    for (index in suffix) block = block.container?.blocks?.getOrNull(index)
        ?: error("Invalid container child address")
    return block
}
internal fun validateBlockPaths(blocks: List<Block>, roots: List<Int>, paths: List<List<Int>>) {
    require(paths.isEmpty() || paths.size == roots.size && paths.any { it.isNotEmpty() }) { "Invalid parallel block addresses" }
    roots.forEachIndexed { i, root -> resolveBlockPath(blocks, root, if (paths.isEmpty()) emptyList() else paths[i]) }
}
data class PresentationForm(val relation: String, val target: String, val language: String)
data class PresentationSense(val block: Int, val parent: Int?, val examples: List<Int>,
    val quotations: List<Int>, val notes: List<Int>, val form: PresentationForm?, val blockPath: List<Int>,
    val examplePaths: List<List<Int>>, val quotationPaths: List<List<Int>>, val notePaths: List<List<Int>>)
data class PresentationLexeme(val language: String, val kind: String, val section: Int, val etymology: Int?,
    val definitions: List<PresentationSense>, val introduction: List<Int>, val otherBlocks: List<Int>,
    val relatedSections: List<Int>, val introductionPaths: List<List<Int>>, val otherBlockPaths: List<List<Int>>)
data class PresentationOrganization(val lexemes: List<PresentationLexeme>, val otherSections: List<Int>)

internal fun PresentationOrganization.validate(sections: List<Section>) {
    fun section(index: Int) = sections.getOrNull(index) ?: error("Invalid organization section")
    otherSections.forEach { section(it) }
    for (lexeme in lexemes) {
        val blocks = section(lexeme.section).blocks
        lexeme.etymology?.let { section(it) }
        lexeme.relatedSections.forEach { section(it) }
        validateBlockPaths(blocks, lexeme.introduction, lexeme.introductionPaths)
        validateBlockPaths(blocks, lexeme.otherBlocks, lexeme.otherBlockPaths)
        lexeme.definitions.forEachIndexed { index, sense ->
            require(sense.parent == null || sense.parent in 0 until index) { "Invalid sense parent" }
            resolveBlockPath(blocks, sense.block, sense.blockPath)
            validateBlockPaths(blocks, sense.examples, sense.examplePaths)
            validateBlockPaths(blocks, sense.quotations, sense.quotationPaths)
            validateBlockPaths(blocks, sense.notes, sense.notePaths)
        }
    }
}
