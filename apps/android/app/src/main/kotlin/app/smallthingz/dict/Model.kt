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
) {
    init {
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

enum class FontScaleBasis { Context, NormalBody }

data class InlineImage(val file: String, val widthPx: Long? = null, val heightPx: Long? = null,
    val alt: String? = null, val tooltip: String? = null) {
    init {
        require(file.isNotEmpty() && validInlineImageString(file) && file.first() != ' ' && file.last() != ' ' &&
            file.none { it.code < 32 || it.code == 127 || it.code in 0x80..0x9f || it in "[]{}<>|#_" }) { "Invalid inline image file" }
        require(widthPx == null || widthPx in 1L..0xffff_ffffL) { "Invalid inline image width" }
        require(heightPx == null || heightPx in 1L..0xffff_ffffL) { "Invalid inline image height" }
        require(alt == null || validInlineImageString(alt)) { "Invalid inline image alt" }
        require(tooltip == null || validInlineImageString(tooltip)) { "Invalid inline image tooltip" }
    }
}
private fun validInlineImageString(value: String): Boolean {
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

enum class TableWidthUnit { Px, Percent }
data class TableWidth(val unit: TableWidthUnit, val value: Long)
data class TableGeometry(val border: Int? = null, val cellSpacing: Int? = null,
                         val cellPadding: Int? = null, val width: TableWidth? = null)
enum class StyleLengthUnit { Px, Em }
data class StyleLength(val unit: StyleLengthUnit, val value: Float) {
    init { require(value.isFinite() && value >= 0f) { "Invalid table style length" } }
}
data class StyleEdges(val top: StyleLength, val right: StyleLength, val bottom: StyleLength, val left: StyleLength)
sealed interface StyleBorder {
    data object None : StyleBorder
    data class Solid(val width: StyleLength, val color: String) : StyleBorder {
        init { require(Regex("#[0-9a-f]{6}").matches(color)) { "Invalid table border RGB" } }
    }
}
enum class TableCollapse { Separate, Collapse }
enum class CellTextAlign { Left, Center, Right }
data class TableStyle(val background: String? = null, val border: StyleBorder? = null,
    val collapse: TableCollapse? = null, val margins: StyleEdges? = null) {
    init {
        require(background != null || border != null || collapse != null || margins != null) { "Empty table style" }
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
    val style: TableStyle? = null)

/** Visit authoritative content exactly once, retaining literal block whitespace policy. */
internal fun Block.visitSpanRuns(visit: (List<Span>, Boolean) -> Unit) {
    if (table != null) table.visitSpanRuns(visit)
    else if (kind != "rule") visit(spans, kind == "preformatted")
}
internal fun Table.visitSpanRuns(visit: (List<Span>, Boolean) -> Unit) {
    visit(caption, false)
    rows.forEach { row -> row.forEach { cell ->
        val blocks = cell.blocks
        if (blocks != null) blocks.forEach { it.visitSpanRuns(visit) }
        else { visit(cell.spans, false); cell.nestedTable?.visitSpanRuns(visit) }
    } }
}
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
)
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
            require(media.size <= 128) { "Too many inline image assets" }
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
    fun clue(): String {
        // Media controls belong in the reader, not a saved word's textual clue.
        fun preview(block: Block) = textOf(block.spans.filterNot { span ->
            span.classes.split(previewClassWhitespace).any { it == "wikidict-media" || it == "audiotable" }
        })
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
        val fallback = StringBuilder(420)
        for (row in readingRows) {
            val block = row.block ?: continue
            if (block.kind in setOf("blank", "rule")) continue
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
}

/** Every serialized span sink participates in asset validation, even an empty
 * occurrence. Plain text/heading authority still uses Span.text and trail only. */
internal fun inlineImageOccurrences(entry: Entry): List<InlineImage> = buildList {
    fun include(spans: List<Span>) { spans.forEach { it.image?.let(::add) } }
    lateinit var block: (Block) -> Unit
    fun table(value: Table) {
        include(value.caption)
        value.rows.forEach { row -> row.forEach { cell ->
            include(cell.spans); cell.nestedTable?.let(::table); cell.blocks?.forEach { block(it) }
        } }
    }
    block = { value -> include(value.spans); value.table?.let(::table) }
    include(entry.displayTitle); include(entry.preamble)
    entry.sections.forEach { section -> section.blocks.forEach { block(it) } }
    entry.references.forEach { reference -> include(reference.spans); reference.blocks?.forEach { block(it) } }
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
internal fun entryAbbreviations(entry: Entry): List<Abbreviation> {
    val result = linkedSetOf<Abbreviation>()
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
                result.add(Abbreviation(label.toString(), annotation, context()))
            label.setLength(0)
        }
        for (span in spans) {
            if (span.kind == "line_break") {
                finish()
                annotation = span.explanation
                label.append(span.trail)
                finish()
                annotation = ""
                continue
            }
            if (span.explanation != annotation) {
                finish()
                annotation = span.explanation
            }
            if (annotation.isNotEmpty()) label.append(span.text).append(span.trail)
        }
        finish()
    }
    include(entry.displayTitle, "Title")
    include(entry.preamble, "About this entry")
    entry.sections.forEach { section ->
        val location = section.title.ifBlank { entry.title }
        lateinit var includeBlock: (Block, String) -> Unit
        fun includeTable(table: Table, tableLocation: String) {
            include(table.caption, "$tableLocation · Table")
            table.rows.forEachIndexed { row, cells -> cells.forEachIndexed { column, cell ->
                val cellLocation = "$tableLocation · Table ${row + 1}, ${column + 1}"
                val blocks = cell.blocks
                if (blocks != null) blocks.forEachIndexed { index, block -> includeBlock(block, "$cellLocation · Block ${index + 1}") }
                else { include(cell.spans, cellLocation); cell.nestedTable?.let { includeTable(it, cellLocation) } }
            } }
        }
        includeBlock = { block, blockLocation ->
            include(block.spans, blockLocation)
            block.table?.let { includeTable(it, blockLocation) }
        }
        section.blocks.forEach { includeBlock(it, location) }
    }

    entry.references.forEach { reference ->
        val location = if (reference.kind == ReferenceKind.Note) "References ${reference.number}" else "References"
        reference.visitSpanRuns { spans, _ -> include(spans, location) }
    }
    return result.toList()
}
