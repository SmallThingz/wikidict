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
enum class ContainerOverflow { Visible, Auto, Hidden }
sealed interface ContainerPositioning {
    data object RelativeAuto : ContainerPositioning
    data class Absolute(val top: StyleLength, val left: StyleLength,
        val ownerFont: InlineFontSnapshot, val lineHeight: InlineComputedLength,
        val textWrap: TextWrap) : ContainerPositioning {
        init {
            require(top.unit == StyleLengthUnit.Px && left.unit == StyleLengthUnit.Px &&
                ownerFont.fontScale != null && ownerFont.fontScaleBasis != FontScaleBasis.Context &&
                lineHeight.value >= 0f && textWrap == TextWrap.NoWrap) { "Unsupported absolute text position" }
        }
    }
}
/** Physical offsets from the nearest represented relative Container padding box. */
data class ContainerAbsolutePosition(val left: ContainerMarginLength, val top: ContainerMarginLength) {
    init { require(left.value.isFinite() && top.value.isFinite()) { "Invalid absolute Container offset" } }
}

/** Source all-auto static position, resolved from the actual containing paragraph. */
enum class ContainerStaticDirection { Inherit, Ltr, Rtl }
data class ContainerAbsoluteStaticPosition(val direction: ContainerStaticDirection = ContainerStaticDirection.Inherit)

private fun ContainerStyle.staticNeutralStyle(): Boolean =
    positionedScope == null && floatSide == null && clear == null && columns == null && layout == null &&
        alignItems == null && flexItem == null && maxWidth == null && minHeight == null &&
        screenMaxWidth == null && overflow == null &&
        (padding == null || listOf(padding.top, padding.right, padding.bottom, padding.left).all { it.value == 0f }) &&
        (margins == null || listOf(margins.top, margins.right, margins.bottom, margins.left).all { it.value == 0f }) &&
        (marginValues == null || listOf(marginValues.top, marginValues.right, marginValues.bottom, marginValues.left)
            .all { it is ContainerMargin.Length && it.value.value == 0f }) &&
        (border == null || border == ContainerBorder.None) &&
        (background == null || background == ContainerColor.Transparent) &&
        (boxSizing == null || boxSizing == ContainerBoxSizing.ContentBox)

internal fun validContainerStaticParentStyle(value: ContainerStyle): Boolean =
    value.positioning == ContainerPositioning.RelativeAuto && value.absolutePosition == null && value.absoluteStatic == null &&
        value.height == null && (value.width == null || value.width == ContainerWidth.Auto) && value.staticNeutralStyle()

private fun containerStaticText(value: String): Boolean = validPresentationString(value) &&
    value.none { it.code < 0x20 || it.code == 0x7f }

/** Local body shape only; the complete entry walk authenticates immediate parent custody. */
internal fun validContainerAbsoluteStaticBody(value: Container): Boolean {
    if (value.style.absoluteStatic == null) return false
    val block = value.blocks.singleOrNull() ?: return false
    if (block.kind != "paragraph" || block.depth != 0 || block.level != 0 || block.spans.isEmpty() ||
        block.spans.size > (1 shl 20) || block.feature != null || block.table != null ||
        block.listPath.isNotEmpty() || block.number.isNotEmpty() || block.anchor.isNotEmpty() ||
        block.anchorFallback.isNotEmpty() || block.style != null || block.figure != null || block.flow != null ||
        block.container != null || block.ruleStyle != null) return false
    if (block.textAlign != null && block.textAlign != value.style.textAlign) return false
    var realText = false
    for (span in block.spans) {
        if (span.kind !in setOf("text", "link", "external_link") || span.image != null || span.ruby != null ||
            span.inlinePaddingGroup != null || span.inlineActionGroup != null || span.inlineBoxGroup != null ||
            span.citationMarker != null || !containerStaticText(span.text) || !containerStaticText(span.trail)) return false
        realText = realText || span.text.isNotEmpty() || span.trail.isNotEmpty()
    }
    return realText
}

internal fun validSoleStaticInlineContainer(parent: Container): Boolean =
    validContainerStaticParentStyle(parent.style) && parent.blocks.singleOrNull()?.container?.let {
        validContainerAbsoluteStaticBody(it)
    } == true

enum class PositionedOverflowX { Scroll, Hidden }
enum class PositionedOverflowY { Auto }
data class PositionedViewportState(val minWidthPx: Long, val overflowX: PositionedOverflowX,
    val overflowY: PositionedOverflowY) {
    init { require(minWidthPx in 1L..0xffff_ffffL) { "Invalid positioned viewport threshold" } }
}
data class PositionedScope(val textWrap: TextWrap, val overflowX: PositionedOverflowX,
    val overflowY: PositionedOverflowY, val viewportStates: List<PositionedViewportState> = emptyList()) {
    init {
        require(textWrap == TextWrap.NoWrap && viewportStates.size <= 16) { "Unsupported positioned scope" }
        require(viewportStates.zipWithNext().all { (first, next) -> first.minWidthPx < next.minWidthPx }) {
            "Positioned viewport states must be strictly ascending"
        }
    }
}
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
data class ContainerColumns(val count: Int?, val gap: StyleLength, val width: StyleLength? = null,
    val direction: BidiResolvedDirection? = null) {
    init {
        require(count == null || count in 1..65535) { "Invalid container column count" }
        require(count != null || width != null) { "Columns require an authored count or width" }
    }
}
enum class GenericFontFamily { SansSerif, Serif }
sealed class ContainerFontFamily {
    data object SansSerif : ContainerFontFamily()
    data class Stack(val names: List<String>, val fallback: GenericFontFamily) : ContainerFontFamily() {
        init {
            require(names.size <= 16 && names.all { name ->
                name.isNotEmpty() && name.length <= 128 && name.first() != ' ' && name.last() != ' ' &&
                    name.all { it.code in 32..126 && it != '[' && it != ']' } &&
                    name.lowercase().split(' ').filter { it.isNotEmpty() }.joinToString(" ") !in genericFontAliases
            }) { "Invalid container font family stack" }
        }
    }
}
private val genericFontAliases = setOf("serif", "sans-serif", "sans serif", "sans", "monospace",
    "cursive", "fantasy", "system", "system-ui", "ui-serif", "ui-sans-serif", "ui-monospace",
    "ui-rounded", "emoji", "math", "fangsong")

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
    val marginValues: ContainerMargins? = null, val fontFamily: ContainerFontFamily? = null,
    val positionedScope: PositionedScope? = null, val ownerFont: InlineFontSnapshot? = null,
    val absolutePosition: ContainerAbsolutePosition? = null, val textWrap: TextWrap? = null,
    val absoluteStatic: ContainerAbsoluteStaticPosition? = null) {
    init {
        ownerFont?.let { font ->
            require(font.fontNormalized && font.fontScale != null &&
                font.fontScaleBasis in listOf(FontScaleBasis.NormalBody, FontScaleBasis.CssPx)) {
                "Container owner font requires a normalized explicit size"
            }
            require((positioning == null || positioning == ContainerPositioning.RelativeAuto) && positionedScope == null) {
                "Container owner font cannot replace a legacy absolute owner"
            }
            require(ownerFontScale == null || font.fontScaleBasis == FontScaleBasis.NormalBody &&
                ownerFontScale == font.fontScale) { "Container owner font scale alias disagrees" }
            require(fontFamily == null || font.fontFamily == fontFamily) {
                "Container owner font family alias disagrees"
            }
        }
        require(textWrap == null || textWrap == TextWrap.Normal || textWrap == TextWrap.NoWrap) {
            "Unsupported Container text wrap"
        }
        if (absoluteStatic != null) {
            require(absolutePosition == null && positioning == null && width == ContainerWidth.FitContent &&
                height == null && staticNeutralStyle()) { "Unsupported static inline Container box" }
        }
        if (absolutePosition != null) {
            val definiteWidth = (width as? ContainerWidth.Length)?.value
            require(positioning == null && positionedScope == null && definiteWidth != null &&
                definiteWidth.unit != StyleWidthUnit.Percent && height != null &&
                floatSide == null && clear == null && columns == null && layout == null && alignItems == null &&
                flexItem == null && maxWidth == null && minHeight == null && screenMaxWidth == null && overflow == null &&
                (boxSizing == null || boxSizing == ContainerBoxSizing.ContentBox) &&
                (padding == null || listOf(padding.top, padding.right, padding.bottom, padding.left).all { it.value == 0f }) &&
                (margins == null || listOf(margins.top, margins.right, margins.bottom, margins.left).all { it.value == 0f }) &&
                (marginValues == null || listOf(marginValues.top, marginValues.right, marginValues.bottom, marginValues.left)
                    .all { it is ContainerMargin.Length && it.value.value == 0f }) &&
                (border == null || border == ContainerBorder.None) &&
                (background == null || background == ContainerColor.Transparent)) {
                "Unsupported absolute Container box"
            }
        }
        if (positioning is ContainerPositioning.Absolute) {
            require(positionedScope == null && floatSide == null && columns == null && screenMaxWidth == null &&
                marginValues == null && overflow == null && layout != ContainerLayout.FlexRow && flexItem == null &&
                minHeight == null && maxWidth == null && border == null && padding == null && margins == null &&
                ownerFontScale == null && fontFamily == null && width == ContainerWidth.Length(StyleWidth(StyleWidthUnit.Percent, 100f)) &&
                height == StyleLength(StyleLengthUnit.Px, 0f) && lineHeight == null) { "Unsupported absolute text box" }
        }
        if (positionedScope != null) {
            require(positioning == ContainerPositioning.RelativeAuto && overflow == null && columns == null &&
                floatSide == null && layout != ContainerLayout.FlexRow && flexItem == null && screenMaxWidth == null &&
                (padding == null || padding.left.value == 0f && padding.right.value == 0f)) {
                "Unsupported positioned containing scope"
            }
        }
        require(overflow != ContainerOverflow.Hidden || columns == null) {
            "Hidden overflow cannot carry column fragmentation"
        }
        if (columns?.width != null || columns?.direction != null) {
            require(height == null && minHeight == null && layout != ContainerLayout.FlexRow &&
                overflow != ContainerOverflow.Auto && positioning == null && absolutePosition == null) {
                "Unsupported extended column fragmentation"
            }
        }
        require(margins == null || marginValues == null) { "Conflicting container margin representations" }
        require(alignItems == null || layout == ContainerLayout.FlexRow) { "Alignment requires a flex row" }
        require(ownerFontScale == null || ownerFontScale.isFinite() && ownerFontScale >= 0f) {
            "Invalid container owner font scale"
        }
    }

    internal fun textContext(inherited: ContainerTextContext): ContainerTextContext {
        if (ownerFont != null || inherited.containerText != null) {
            val previous = inherited.containerText
            val snapshot = ownerFont ?: checkNotNull(previous).snapshot.let { font ->
                font.copy(fontScale = ownerFontScale ?: font.fontScale,
                    fontScaleBasis = if (ownerFontScale == null) font.fontScaleBasis else FontScaleBasis.NormalBody,
                    fontFamily = fontFamily ?: font.fontFamily)
            }
            val state = NativeContainerTextState(snapshot,
                resolved = previous?.resolved.takeIf { ownerFont == null && previous?.snapshot == snapshot },
                lineHeight = if (lineHeight != null) null else previous?.lineHeight ?: inherited.cellText?.lineHeight)
            return ContainerTextContext(ownerFontScale ?: snapshot.fontScale.takeIf {
                snapshot.fontScaleBasis == FontScaleBasis.NormalBody
            } ?: inherited.ownerFontScale, lineHeight ?: inherited.lineHeight, cellText = null,
                fontFamily = snapshot.fontFamily ?: fontFamily ?: inherited.fontFamily, containerText = state,
                bodyOrigin = inherited.bodyOrigin?.copy(
                    fontInherited = inherited.bodyOrigin.fontInherited && ownerFont == null,
                    lineHeightInherited = inherited.bodyOrigin.lineHeightInherited && lineHeight == null,
                    sizeInherited = inherited.bodyOrigin.sizeInherited && ownerFontScale == null,
                    familyInherited = inherited.bodyOrigin.familyInherited && fontFamily == null),
                resolvedLineHeight = inherited.resolvedLineHeight.takeIf { lineHeight == null },
                bodyDirection = inherited.bodyDirection)
        }
        val previous = inherited.cellText
        val metricFont = previous?.ownerFont?.snapshot
        val sameScale = ownerFontScale == null || metricFont != null &&
            metricFont.fontScaleBasis == FontScaleBasis.NormalBody && metricFont.fontScale == ownerFontScale
        val sameFamily = fontFamily == null || metricFont != null && metricFont.fontFamily == fontFamily
        return ContainerTextContext(ownerFontScale ?: inherited.ownerFontScale, lineHeight ?: inherited.lineHeight,
            previous?.copy(fontPixels = if (ownerFontScale == null || metricFont != null && sameScale) previous.fontPixels else null,
                lineHeight = if (lineHeight == null) previous.lineHeight else null,
                // Preserve the original Cell contribution; an incomplete descendant font
                // change cannot issue a new metric owner or silently revert to a default.
                ownerFontInvalidated = previous.ownerFontInvalidated || metricFont != null && (!sameScale || !sameFamily)),
            fontFamily ?: inherited.fontFamily, bodyOrigin = inherited.bodyOrigin?.copy(
                lineHeightInherited = inherited.bodyOrigin.lineHeightInherited && lineHeight == null,
                sizeInherited = inherited.bodyOrigin.sizeInherited && ownerFontScale == null,
                familyInherited = inherited.bodyOrigin.familyInherited && fontFamily == null),
            resolvedLineHeight = inherited.resolvedLineHeight.takeIf { lineHeight == null },
            bodyDirection = inherited.bodyDirection)
    }

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
    val cellText: NativeCellTextState? = null, val fontFamily: ContainerFontFamily? = null,
    val containerText: NativeContainerTextState? = null,
    val bodyOrigin: NativeBodyTextOrigin? = null,
    val resolvedLineHeight: NativeLineHeightPolicy? = null,
    // BODY/reference paragraph provenance is independent of font and line-height ownership.
    val bodyDirection: BidiResolvedDirection? = null) {
    init { require(ownerFontScale.isFinite() && ownerFontScale >= 0f) }
}

/** Rendering state, not a new wire field. Auto margins survive until used box geometry is known. */
internal data class ContainerViewportStyle(val box: ContainerStyle, val margins: ContainerMargins?) {
    init { require(box.screenMaxWidth == null && box.margins == null && box.marginValues == null) }
    val ownsFormattingContext: Boolean get() = box.floatSide != null ||
        box.layout == ContainerLayout.FlexRow || box.overflow == ContainerOverflow.Auto ||
        box.overflow == ContainerOverflow.Hidden || box.columns != null
}
internal fun ContainerStyle.requiresPositionedContainers(): Boolean = absolutePosition != null || absoluteStatic != null || textWrap != null ||
    ownerFont != null && positioning == ContainerPositioning.RelativeAuto

enum class ContainerDisclosureFocusMode { AuthoredNone, UaAuto }
data class ContainerDisclosureFocusPaint(val mode: ContainerDisclosureFocusMode, val color: FigureColor? = null) {
    init {
        require(color == null || mode == ContainerDisclosureFocusMode.UaAuto &&
            (color == FigureColor.Transparent || color is FigureColor.Rgb)) {
            "Disclosure focus color requires automatic RGB or transparent paint"
        }
    }
}
enum class ContainerDisclosurePlacement { InlineFlow, FloatLeft, FloatRight }
/** A button has four independent pointer states and no visited history. */
data class ContainerDisclosureTextPaint(val normal: LinkState, val hover: LinkState, val active: LinkState,
    val hoverActive: LinkState, val underlineOnFocus: Boolean = false)
data class ContainerDisclosureLabelRun(val start: Long, val end: Long, val paint: ContainerDisclosureTextPaint) {
    init { require(start in 0..0xffff_ffffL && end in 0..0xffff_ffffL && start < end) { "Invalid disclosure label range" } }
}
/** Original UTF-8 byte boundaries; the label has already passed strict string validation. */
private fun validDisclosureRun(label: String, run: ContainerDisclosureLabelRun): Boolean {
    var bytes = 0L
    var index = 0
    var starts = run.start == 0L
    var ends = false
    while (index < label.length) {
        val char = label[index++]
        bytes += when {
            Character.isHighSurrogate(char) -> { index++; 4 }
            char.code < 0x80 -> 1
            char.code < 0x800 -> 2
            else -> 3
        }
        if (bytes == run.start) starts = true
        if (bytes == run.end) ends = true
    }
    return starts && ends
}
data class ContainerDisclosure(val contentIndex: Long, val initiallyCollapsed: Boolean,
    val expandLabel: String, val collapseLabel: String, val focus: ContainerDisclosureFocusPaint? = null,
    val placement: ContainerDisclosurePlacement = ContainerDisclosurePlacement.InlineFlow,
    val foreground: FigureColor? = null, val direction: BidiResolvedDirection? = null,
    val expandRun: ContainerDisclosureLabelRun? = null, val collapseRun: ContainerDisclosureLabelRun? = null) {
    init {
        require(contentIndex in 0..0xffff_ffffL) { "Invalid disclosure child index" }
        require(listOf(expandLabel, collapseLabel).all { label -> label.isNotEmpty() &&
            validPresentationString(label) && label.none { it.code < 0x20 || it.code == 0x7f } }) {
            "Invalid complete disclosure label"
        }
        require(foreground == null || foreground == FigureColor.Transparent || foreground is FigureColor.Rgb) {
            "Disclosure foreground requires RGB or transparent paint"
        }
        require(expandRun == null || validDisclosureRun(expandLabel, expandRun)) { "Invalid expand label UTF-8 range" }
        require(collapseRun == null || validDisclosureRun(collapseLabel, collapseRun)) { "Invalid collapse label UTF-8 range" }
    }
}
internal fun validContainerDisclosureOwner(value: Container): Boolean {
    val disclosure = value.disclosure ?: return true
    if (disclosure.contentIndex >= value.blocks.size.toLong()) return false
    val child = value.blocks[disclosure.contentIndex.toInt()]
    return child.kind == "container" && child.container != null
}

data class Container(val blocks: List<Block>, val style: ContainerStyle = ContainerStyle(),
    val disclosure: ContainerDisclosure? = null) {
    init {
        require(supportedContainerShape(this, 1)) { "Unsupported container heading, positioning or depth" }
        if (style.positionedScope != null) {
            val visitor = PresentationSpanVisitor { _, _ -> }
            visitor.onContainer = { require(it.style.positionedScope == null) { "Nested positioned scope is unsupported" } }
            visitor.blocks(blocks)
        }
    }
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
        block.ruleStyle?.margins?.hasVerticalMargin() != true &&
        (block.container == null || legacyContainerMarginsSupported(block.container, depth + 1)) }
}

private fun supportedContainerShape(value: Container, depth: Int): Boolean {
    if (depth > MaxContentDepth || value.blocks.size > (1 shl 20) || !validContainerDisclosureOwner(value)) return false
    if (value.style.absoluteStatic != null && !validContainerAbsoluteStaticBody(value)) return false
    return value.blocks.all { block -> block.kind != "heading" &&
        (block.container == null ||
            (block.container.style.positioning !is ContainerPositioning.Absolute || value.style.positionedScope != null) &&
                supportedContainerShape(block.container, depth + 1)) }
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
