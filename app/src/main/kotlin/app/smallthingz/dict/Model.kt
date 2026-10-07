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
)

data class Cell(val spans: List<Span>, val header: Boolean, val colspan: Int, val rowspan: Int)
data class Table(val caption: List<Span>, val rows: List<List<Cell>>)
data class Block(
    val kind: String,
    val depth: Int,
    val spans: List<Span>,
    val listPath: String = "",
    val number: String = "",
    val table: Table? = null,
    val feature: Feature? = null,
)
data class Feature(val kind: String, val language: String, val data: String, val tailKind: String, val tail: String)
data class Section(val level: Int, val title: String, val blocks: List<Block>)
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
) {
    val key: String = origin?.takeIf { edition.isNotEmpty() || redirect != null }?.let {
        "${it.dictionary}\u0000${it.contextDictionary.orEmpty()}\u0000${it.recordKey}"
    } ?: "$kind\u0000${language.orEmpty()}\u0000$title"
    // Constructed with the decoded entry on the import dispatcher.
    val readingRows: List<ReadingRow> = readingRows(sections)
    fun clue(): String {
        val definition = sections.asSequence().flatMap { it.blocks.asSequence() }
            .firstOrNull { it.kind == "definition" && textOf(it.spans).isNotBlank() }
        val fallback = sections.asSequence().flatMap { it.blocks.asSequence() }
            .firstOrNull { it.kind !in setOf("blank", "rule") && textOf(it.spans).isNotBlank() }
        return textOf((definition ?: fallback)?.spans.orEmpty()).ifBlank { "Definition unavailable." }.take(420)
    }
}

fun textOf(spans: List<Span>): String = spans.joinToString("") { it.text + it.trail }
    .replace(Regex("\\s+"), " ").trim()
