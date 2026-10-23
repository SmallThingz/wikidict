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
)

internal const val MaxTableDepth = 16

enum class TableWidthUnit { Px, Percent }
data class TableWidth(val unit: TableWidthUnit, val value: Long)
data class TableGeometry(val border: Int? = null, val cellSpacing: Int? = null,
                         val cellPadding: Int? = null, val width: TableWidth? = null)
data class Cell(val spans: List<Span>, val header: Boolean, val colspan: Int, val rowspan: Int,
                val background: String? = null, val nestedTable: Table? = null) {
    init { require(nestedTable == null || spans.isEmpty()) { "A nested table cell cannot also contain spans" } }
}
data class Table(val caption: List<Span>, val rows: List<List<Cell>>, val geometry: TableGeometry? = null)

/** Ordered traversal of the compiled table tree; no textual substitute for a grid. */
internal fun Table.visitSpans(visit: (List<Span>) -> Unit) {
    visit(caption)
    rows.forEach { row -> row.forEach { cell ->
        visit(cell.spans)
        cell.nestedTable?.visitSpans(visit)
    } }
}
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
data class Reference(val number: Int, val groupNumber: Int, val group: String, val spans: List<Span>)
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
) {
    val key: String = origin?.key ?: "$kind\u0000${language.orEmpty()}\u0000$title"
    // Constructed with the decoded entry on the import dispatcher.
    val readingRows: List<ReadingRow> = readingRows(sections, media)
    internal val abbreviations: List<Abbreviation> = entryAbbreviations(this)
    fun clue(): String {
        // Media controls belong in the reader, not a saved word's textual clue.
        fun preview(block: Block) = textOf(block.spans.filterNot { span ->
            span.classes.split(previewClassWhitespace).any { it == "wikidict-media" || it == "audiotable" }
        })
        val blocks = sections.asSequence().flatMap { it.blocks.asSequence() }
        val definition = blocks.filter { it.kind == "definition" }.map(::preview).firstOrNull { it.isNotBlank() }
        val fallback = definition ?: blocks.filter { it.kind !in setOf("blank", "rule") }
            .map(::preview).firstOrNull { it.isNotBlank() }
        return (fallback ?: "Definition unavailable.").take(420)
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
        section.blocks.forEach { block ->
            include(block.spans, location)
            fun includeTable(table: Table, tableLocation: String) {
                include(table.caption, "$tableLocation · Table")
                table.rows.forEachIndexed { row, cells -> cells.forEachIndexed { column, cell ->
                    val cellLocation = "$tableLocation · Table ${row + 1}, ${column + 1}"
                    include(cell.spans, cellLocation)
                    cell.nestedTable?.let { includeTable(it, cellLocation) }
                } }
            }
            block.table?.let { includeTable(it, location) }
        }
    }
    entry.references.forEach { include(it.spans, "References ${it.number}") }
    return result.toList()
}
