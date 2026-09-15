package app.smallthingz.dict

import org.json.JSONArray
import org.json.JSONObject

data class Span(
    val kind: String,
    val text: String,
    val target: String = "",
    val trail: String = "",
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
)
data class Section(val level: Int, val title: String, val blocks: List<Block>)
data class Reference(val number: Int, val groupNumber: Int, val group: String, val spans: List<Span>)
data class Entry(
    val title: String,
    val kind: String,
    val language: String?,
    val languageCode: String,
    val sections: List<Section>,
    val references: List<Reference>,
) {
    val key: String get() = "$kind\u0000${language.orEmpty()}\u0000$title"
    fun clue(): String {
        val definition = sections.asSequence().flatMap { it.blocks.asSequence() }
            .firstOrNull { it.kind == "definition" && textOf(it.spans).isNotBlank() }
        val fallback = sections.asSequence().flatMap { it.blocks.asSequence() }
            .firstOrNull { it.kind !in setOf("blank", "rule") && textOf(it.spans).isNotBlank() }
        return textOf((definition ?: fallback)?.spans.orEmpty()).ifBlank { "Definition unavailable in this export." }.take(420)
    }
}

data class Results(
    val schema: String,
    val query: String,
    val kind: String,
    val language: String?,
    val entries: List<Entry>,
)

private val forbiddenCompiledFields = setOf(
    "source", "source_base64", "payload_base64", "unexpanded_templates",
    "rendered_templates", "expansion", "deferred", "content",
)

fun compiledFieldName(name: String): String {
    require(name !in forbiddenCompiledFields) { "Dictionary package contains legacy uncompiled reader field: $name" }
    return name
}

fun compiledSpanKind(kind: String): String {
    require(kind != "template") { "Dictionary package contains uncompiled template markup." }
    return kind
}

fun textOf(spans: List<Span>): String = spans.joinToString("") { it.text + it.trail }
    .replace(Regex("\\s+"), " ").trim()
object ResultParser {
    fun parse(json: String): Results {
        val root = JSONObject(json)
        require(root.optString("schema") == "dict.results.v1") { "Unsupported dictionary export." }
        val entries = root.optJSONArray("entries") ?: JSONArray()
        return Results(
            schema = root.getString("schema"),
            query = root.optString("query"),
            kind = root.optString("kind", "language"),
            language = root.stringOrNull("language"),
            entries = (0 until entries.length()).map { entry(entries.getJSONObject(it)) },
        )
    }

    private fun entry(value: JSONObject): Entry {
        rejectLegacyFields(value)
        val sections = value.optJSONArray("sections") ?: JSONArray()
        val references = value.optJSONArray("references") ?: JSONArray()
        return Entry(
            title = value.getString("title"),
            kind = value.optString("kind", "language"),
            language = value.stringOrNull("language"),
            languageCode = value.optString("language_code"),
            sections = (0 until sections.length()).map { section(sections.getJSONObject(it)) },
            references = (0 until references.length()).map { reference(references.getJSONObject(it)) },
        )
    }
    private fun section(value: JSONObject): Section {
        rejectLegacyFields(value)
        val blocks = value.optJSONArray("blocks") ?: JSONArray()
        return Section(
            level = value.optInt("level", 2),
            title = value.optString("title"),
            blocks = (0 until blocks.length()).map { block(blocks.getJSONObject(it)) },
        )
    }

    private fun block(value: JSONObject): Block {
        rejectLegacyFields(value)
        val spans = value.optJSONArray("spans") ?: JSONArray()
        return Block(
            kind = value.optString("kind", "paragraph"),
            depth = value.optInt("depth"),
            spans = (0 until spans.length()).map { span(spans.getJSONObject(it)) },
            listPath = value.optString("list_path"),
            number = value.optString("number"),
            table = value.optJSONObject("table")?.let(::table),
        )
    }

    private fun span(value: JSONObject): Span {
        rejectLegacyFields(value)
        val kind = compiledSpanKind(value.optString("kind", "text"))
        return Span(
            kind = kind, text = value.optString("text"),
            target = value.optString("target"), trail = value.optString("trail"),
            bold = value.optBoolean("bold"), italic = value.optBoolean("italic"),
            code = value.optBoolean("code"), small = value.optBoolean("small"),
            superscript = value.optBoolean("superscript"), subscript = value.optBoolean("subscript"),
            strike = value.optBoolean("strike"), underline = value.optBoolean("underline"),
            role = value.optString("role", "normal"),
        )
    }
    private fun table(value: JSONObject): Table {
        val caption = value.optJSONArray("caption") ?: JSONArray()
        val rows = value.optJSONArray("rows") ?: JSONArray()
        return Table(
            caption = (0 until caption.length()).map { span(caption.getJSONObject(it)) },
            rows = (0 until rows.length()).map { rowIndex ->
                val cells = rows.getJSONObject(rowIndex).optJSONArray("cells") ?: JSONArray()
                (0 until cells.length()).map { cellIndex ->
                    val cell = cells.getJSONObject(cellIndex)
                    val spans = cell.optJSONArray("spans") ?: JSONArray()
                    Cell(
                        spans = (0 until spans.length()).map { span(spans.getJSONObject(it)) },
                        header = cell.optBoolean("header"),
                        colspan = cell.optInt("colspan", 1).coerceIn(1, 100),
                        rowspan = cell.optInt("rowspan", 1).coerceIn(1, 100),
                    )
                }
            },
        )
    }

    private fun reference(value: JSONObject): Reference {
        val spans = value.optJSONArray("spans") ?: JSONArray()
        return Reference(
            number = value.optInt("number"),
            groupNumber = value.optInt("group_number", value.optInt("number")),
            group = value.optString("group"),
            spans = (0 until spans.length()).map { span(spans.getJSONObject(it)) },
        )
    }
}


private fun rejectLegacyFields(value: JSONObject) {
    forbiddenCompiledFields.forEach { field -> require(!value.has(field)) { "Dictionary package contains legacy uncompiled reader field: $field" } }
}

private fun JSONObject.stringOrNull(name: String): String? = if (isNull(name) || !has(name)) null else optString(name).takeIf { it.isNotBlank() }
