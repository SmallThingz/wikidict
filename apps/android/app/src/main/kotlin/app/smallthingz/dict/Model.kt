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
) {
    init {
        require(tooltip == null || validPresentationString(tooltip)) { "Invalid span tooltip" }
        require(targetFragment == null || kind == "link") { "Only internal links may carry a target fragment" }
        require(targetFragment == null || validPresentationString(targetFragment)) { "Invalid link target fragment" }
        require(fontScaleBasis != FontScaleBasis.NormalBody || fontScale != null) {
            "Normal-body font scale requires a value"
        }
        require(image == null || when (kind) {
            "text" -> target.isEmpty()
            "link", "external_link" -> target.isNotEmpty()
            else -> false
        }) { "Invalid inline image action" }
        require(image == null || (text.isEmpty() && trail.isEmpty())) { "Inline image occurrences cannot also contain text" }
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

enum class FontScaleBasis { Context, NormalBody }

data class InlineImage(val file: String, val widthPx: Long? = null, val heightPx: Long? = null,
    val alt: String? = null, val tooltip: String? = null, val border: Boolean = false, val map: ImageMap? = null) {
    init {
        require(file.isNotEmpty() && validPresentationString(file) && file.first() != ' ' && file.last() != ' ' &&
            file.none { it.code < 32 || it.code == 127 || it.code in 0x80..0x9f || it in "[]{}<>|#_" }) { "Invalid inline image file" }
        require(widthPx == null || widthPx in 1L..0xffff_ffffL) { "Invalid inline image width" }
        require(heightPx == null || heightPx in 1L..0xffff_ffffL) { "Invalid inline image height" }
        require(alt == null || validPresentationString(alt)) { "Invalid inline image alt" }
        require(tooltip == null || validPresentationString(tooltip)) { "Invalid inline image tooltip" }
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

private fun validPresentationString(value: String): Boolean {
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
internal fun spanFontScale(span: Span): Float =
    (span.fontScale ?: 1f) * if (span.small || span.superscript || span.subscript) 0.8f else 1f

// Blink kMaximumAllowedFontSize / GetComputedSizeFromSpecifiedSize cap computed
// pixels, after the typography/zoom context. This never changes stored scale.
internal const val MaxComputedFontPixels = 10000f
internal fun spanFontPixels(span: Span, contextPixels: Float, normalBodyPixels: Float): Float {
    require(contextPixels.isFinite() && contextPixels >= 0f)
    require(normalBodyPixels.isFinite() && normalBodyPixels >= 0f)
    val scale = span.fontScale ?: 1f
    require(scale.isFinite() && scale >= 0f)
    val base = if (span.fontScaleBasis == FontScaleBasis.NormalBody) normalBodyPixels else contextPixels
    val legacy = if (span.small || span.superscript || span.subscript) 0.8 else 1.0
    return (base.toDouble() * scale.toDouble() * legacy).coerceAtMost(MaxComputedFontPixels.toDouble()).toFloat()
}

internal const val MaxTableDepth = 16
internal const val MaxContentDepth = 16

enum class TableWidthUnit { Px, Percent }
data class TableWidth(val unit: TableWidthUnit, val value: Long)
data class TableGeometry(val border: Int? = null, val cellSpacing: Int? = null,
                         val cellPadding: Int? = null, val width: TableWidth? = null)
enum class StyleLengthUnit { Px, Em }
data class StyleLength(val unit: StyleLengthUnit, val value: Float) {
    init { require(value.isFinite() && value >= 0f) { "Invalid table style length" } }
}
data class StyleEdges(val top: StyleLength, val right: StyleLength, val bottom: StyleLength, val left: StyleLength)
data class BlockStyle(val margins: StyleEdges? = null, val padding: StyleEdges? = null) {
    init { require(margins != null || padding != null) { "Empty block style" } }
}
sealed interface StyleBorder {
    data object None : StyleBorder
    data class Solid(val width: StyleLength, val color: String) : StyleBorder {
        init { require(Regex("#[0-9a-f]{6}").matches(color)) { "Invalid table border RGB" } }
    }
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
data class Figure(val imageSpan: Span, val format: FigureFormat, val placement: FigurePlacement,
    val clear: FigureClear, val margins: StyleEdges, val imageInsets: StyleEdges, val captionPadding: StyleEdges,
    val captionFontScale: Float, val captionLineHeight: StyleLength,
    val frameBackground: FigureColor, val frameBorder: FigureBorder,
    val imageBackground: FigureColor, val imageBorder: FigureBorder,
    val captionForeground: FigureColor, val captionBackground: FigureColor,
    val caption: List<Span> = emptyList(), val captionBlocks: List<Block>? = null,
    val captionTextAlign: CellTextAlign? = null, val sizing: FigureSizingPolicy,
    val frameMinWidth: StyleLength? = null) {
    init {
        require(frameMinWidth == null || frameMinWidth.unit == StyleLengthUnit.Px) { "Unsupported figure frame minimum unit" }
        require(imageSpan.image != null && imageSpan.text.isEmpty() && imageSpan.trail.isEmpty()) { "Figure requires one image span" }
        require(validFigureSizingContext(format, sizing, imageSpan.image.widthPx, imageSpan.image.heightPx)) { "Invalid figure sizing context" }
        require(captionBlocks == null || caption.isEmpty()) { "Rich figure caption owns its content" }
        require(captionFontScale.isFinite() && captionFontScale >= 0f) { "Invalid figure caption scale" }
        require(imageSpan.fontScale == null || imageSpan.fontScale.isFinite() && imageSpan.fontScale >= 0f) { "Invalid figure image font scale" }
        require(imageSpan.foreground == null || Regex("#[0-9a-f]{6}").matches(imageSpan.foreground)) { "Invalid figure image foreground" }
        require(imageSpan.background == null || Regex("#[0-9a-f]{6}").matches(imageSpan.background)) { "Invalid figure image background" }
    }
}

enum class TableCollapse { Separate, Collapse }
enum class CellTextAlign { Left, Center, Right }
enum class TableFloatSide { Left, Right }
enum class StyleWidthUnit { Px, Em, Percent }
data class StyleWidth(val unit: StyleWidthUnit, val value: Float) {
    init { require(value.isFinite() && value >= 0f) { "Invalid style width" } }
}
data class TableStyle(val background: String? = null, val border: StyleBorder? = null,
    val collapse: TableCollapse? = null, val margins: StyleEdges? = null, val floatSide: TableFloatSide? = null,
    val width: StyleWidth? = null, val padding: StyleEdges? = null, val clear: FigureClear? = null) {
    init {
        require(background != null || border != null || collapse != null || margins != null || floatSide != null ||
            width != null || padding != null || clear != null) { "Empty table style" }
        require(background == null || Regex("#[0-9a-f]{6}").matches(background)) { "Invalid table background RGB" }
    }
}
data class CellStyle(val border: StyleBorder? = null, val padding: StyleEdges? = null,
    val textAlign: CellTextAlign? = null) {
    init { require(border != null || padding != null || textAlign != null) { "Empty cell style" } }
}
data class Cell(val spans: List<Span>, val header: Boolean, val colspan: Int, val rowspan: Int,
                val background: String? = null, val nestedTable: Table? = null, val blocks: List<Block>? = null,
                val style: CellStyle? = null) {
    init {
        require(nestedTable == null || spans.isEmpty()) { "A nested table cell cannot also contain spans" }
        require(blocks == null || (spans.isEmpty() && nestedTable == null)) { "Ordered cell blocks cannot also contain legacy content" }
    }
}
data class Table(val caption: List<Span>, val rows: List<List<Cell>>, val geometry: TableGeometry? = null,
    val style: TableStyle? = null, val captionBlocks: List<Block>? = null) {
    init { require(captionBlocks == null || caption.isEmpty()) { "Rich table caption owns its content" } }
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

/** Authoritative content only. Table depth and content depth never reset at a sink. */
internal class PresentationSpanVisitor(private val visit: (List<Span>, Boolean) -> Unit) {
    private var remaining = 1 shl 20
    private fun charge(count: Int) { require(count <= remaining) { "Presentation item budget exceeded" }; remaining -= count }
    private fun descend(depth: Int): Int { require(depth < MaxContentDepth) { "Content nesting is too deep" }; return depth + 1 }
    fun spans(value: List<Span>, preformatted: Boolean = false) { charge(value.size); visit(value, preformatted) }
    fun blocks(value: List<Block>, tableDepth: Int = 0, contentDepth: Int = 0) {
        charge(value.size); value.forEach { block(it, tableDepth, contentDepth) }
    }
    fun block(value: Block, tableDepth: Int = 0, contentDepth: Int = 0) {
        when {
            value.table != null -> table(value.table, tableDepth + 1, contentDepth)
            value.figure != null -> figure(value.figure, tableDepth, contentDepth)
            value.flow != null -> parts(value.flow, tableDepth, descend(contentDepth))
            value.kind != "rule" -> spans(value.spans, value.kind == "preformatted")
        }
    }
    fun figure(value: Figure, tableDepth: Int, contentDepth: Int) {
        spans(listOf(value.imageSpan))
        val rich = value.captionBlocks
        if (rich == null) spans(value.caption) else blocks(rich, tableDepth, descend(contentDepth))
    }
    fun parts(value: List<FlowPart>, tableDepth: Int, contentDepth: Int) {
        charge(value.size)
        value.forEach { part -> when (part) {
            is FlowPart.Inline -> spans(part.spans)
            is FlowPart.ImageFigure -> figure(part.figure, tableDepth, contentDepth)
            is FlowPart.Scope -> parts(part.scope.parts, tableDepth, descend(contentDepth))
        } }
    }
    fun table(value: Table, tableDepth: Int = 1, contentDepth: Int = 0) {
        require(tableDepth <= MaxTableDepth) { "Table nesting is too deep" }
        val rich = value.captionBlocks
        if (rich == null) spans(value.caption) else blocks(rich, tableDepth, descend(contentDepth))
        charge(value.rows.size)
        value.rows.forEach { row -> charge(row.size); row.forEach { cell ->
            when {
                cell.blocks != null -> blocks(cell.blocks, tableDepth, contentDepth)
                cell.nestedTable != null -> table(cell.nestedTable, tableDepth + 1, contentDepth)
                else -> spans(cell.spans)
            }
        } }
    }
}
internal fun Block.visitSpanRuns(visit: (List<Span>, Boolean) -> Unit) = PresentationSpanVisitor(visit).block(this)
internal fun Table.visitSpanRuns(visit: (List<Span>, Boolean) -> Unit) = PresentationSpanVisitor(visit).table(this)
internal fun Table.visitSpans(visit: (List<Span>) -> Unit) = visitSpanRuns { spans, _ -> visit(spans) }
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
) {
    init {
        require(figure == null || (spans.isEmpty() && table == null && feature == null && style == null &&
            flow == null && acceptsAnonymousContent())) { "Figure requires one content owner" }
        require(flow == null || (spans.isEmpty() && table == null && feature == null && figure == null &&
            acceptsAnonymousContent())) { "Anonymous flow requires one content owner" }
        require(style == null || (kind == "paragraph" && depth == 0 && listPath.isEmpty() && table == null && feature == null)) {
            "Block style requires an ordinary paragraph"
        }
    }
}
data class Feature(val kind: String, val language: String, val data: String, val tailKind: String, val tail: String)
data class Section(val level: Int, val title: String, val blocks: List<Block>, val anchor: String = "", val anchorFallback: String = "")
data class Media(val file: String, val kind: String, val caption: String)
enum class ReferenceKind { Note, Fragment }
data class Reference(val number: Long, val groupNumber: Long?, val group: String, val spans: List<Span>,
    val kind: ReferenceKind = ReferenceKind.Note, val blocks: List<Block>? = null) {
    init {
        require(blocks == null || spans.isEmpty()) { "Ordered reference blocks cannot also contain legacy spans" }
        require(number in 1L..0xffff_fffeL) { "Reference item identity is outside the wire range" }
        require(if (kind == ReferenceKind.Note) groupNumber != null && groupNumber in 1L..0xffff_fffeL else groupNumber == null) {
            "Only numbered notes have a valid wire group ordinal"
        }
    }
}
internal fun Reference.visitSpanRuns(visit: (List<Span>, Boolean) -> Unit) {
    val content = blocks
    if (content != null) content.forEach { it.visitSpanRuns(visit) }
    else visit(spans, false)
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
) {
    internal val inlineImages: List<InlineImage> = inlineImageOccurrences(this)
    init {
        val occurrences = inlineImages
        if (occurrences.isNotEmpty()) {
            val byFile = media.groupBy { it.file }
            occurrences.forEach { image ->
                val matching = byFile[image.file]
                require(matching != null && matching.size == 1 && matching.single().kind == "image") { "Inline image asset is absent or ambiguous" }
            }
        }
    }
    val key: String = origin?.key ?: "$kind\u0000${language.orEmpty()}\u0000$title"
    // Constructed with the decoded entry on the import dispatcher.
    val readingRows: List<ReadingRow> = readingRows(sections, media, etymologySections)
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
        return fallback.toString().ifEmpty { "Definition unavailable." }
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
 * occurrence. Plain text/heading authority still uses Span.text and trail only. */
internal fun inlineImageOccurrences(entry: Entry): List<InlineImage> = buildList {
    val visitor = PresentationSpanVisitor { spans, _ -> spans.forEach { it.image?.let(::add) } }
    visitor.spans(entry.displayTitle); visitor.spans(entry.preamble)
    entry.sections.forEach { visitor.blocks(it.blocks) }
    entry.references.forEach { reference ->
        val blocks = reference.blocks
        if (blocks == null) visitor.spans(reference.spans) else visitor.blocks(blocks)
    }
}

internal fun WordHit.isInstalled(installed: (String) -> Boolean): Boolean =
    installed(dictionary) && (contextDictionary == null || installed(contextDictionary))

internal fun Entry.isInstalled(installed: (String) -> Boolean): Boolean =
    origin?.isInstalled(installed) == true && contentDictionary?.let(installed) == true

private val previewClassWhitespace = Regex("\\s+")

fun textOf(spans: List<Span>): String = spans.joinToString("") { it.text + it.trail }
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
            for (span in spans) {
                val value = if (advisory) span.imageTooltip else span.explanation
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
                    continue
                }
                if (value != annotation || nextKind != kind || nextFile != file) {
                    finish(); annotation = value; kind = nextKind; file = nextFile
                }
                if (!value.isNullOrEmpty()) label.append(text)
            }
            finish()
        }
        collect(false, explanations)
        collect(true, advisories)
    }
    return explanations.toList() + advisories.toList()
}
private fun entryAnnotations(entry: Entry, kind: TextDetailKind, valueOf: (Span) -> String): List<TextDetail> {
    val result = linkedSetOf<TextDetail>()
    fun include(spans: List<Span>, location: String) {
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
        for (span in spans) {
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
            include(listOf(figure.imageSpan), at)
            val rich = figure.captionBlocks
            if (rich == null) include(figure.caption, at) else rich.forEach { includeBlock(it, at) }
        }
        includeParts = { parts, at -> parts.forEach { part -> when (part) {
            is FlowPart.Inline -> include(part.spans, at)
            is FlowPart.ImageFigure -> includeFigure(part.figure, at)
            is FlowPart.Scope -> includeParts(part.scope.parts, at)
        } } }
        includeBlock = { block, blockLocation -> when {
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
