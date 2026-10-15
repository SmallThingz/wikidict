package app.smallthingz.dict


private val compiledClassWhitespace = Regex("\\s+")
internal fun Span.hasClassToken(token: String): Boolean =
    classes.split(compiledClassWhitespace).any { it == token }
internal fun Span.withoutClassToken(token: String): Span =
    copy(classes = classes.split(compiledClassWhitespace).filter { it.isNotEmpty() && it != token }.joinToString(" "))

/** Ownership and lexical navigation are independent compiled fields. */
internal class MediaOwners(media: List<Media>) {
    private val files = media.associateBy { it.file }
    // Only existing catalog names are encoded. No untrusted token is decoded or allocated.
    private val tokens = media.filter { it.file.isNotEmpty() }.associate { item ->
        val bytes = item.file.toByteArray(Charsets.UTF_8)
        val token = buildString {
            append("wikidict-media-file-")
            for (byte in bytes) {
                val value = byte.toInt() and 255
                append("0123456789abcdef"[value ushr 4])
                append("0123456789abcdef"[value and 15])
            }
        }
        token to item.file
    }

    fun file(span: Span): String? {
        val classes = span.classes.split(compiledClassWhitespace)
        if ("wikidict-media" !in classes) return null
        val owners = classes.filter { it.startsWith("wikidict-media-file-") }
        // A present marker is authoritative, including when it is invalid or ambiguous.
        if (owners.isNotEmpty()) return owners.singleOrNull()?.let(tokens::get)
        return span.target.takeIf { it.startsWith("File:") }
            ?.removePrefix("File:")?.replace('_', ' ')
    }

    fun embedded(spans: List<Span>): List<Media> =
        spans.mapNotNull { file(it)?.let(files::get) }.distinctBy { it.file }
}

internal data class PoemParagraph(val start: Int, val end: Int, val indent: Int, val direction: String?)
private data class PoemMetadata(val indent: Int, val direction: String?)

/** Only canonical compiled tokens affect layout; lexical text is never padding. */
private fun poemMetadata(span: Span): PoemMetadata? {
    val tokens = span.classes.split(compiledClassWhitespace)
    if ("wikidict-poem" !in tokens) return null
    val indents = tokens.filter { it.startsWith("wikidict-poem-indent") }
    val token = indents.singleOrNull()
    val depth = token?.removePrefix("wikidict-poem-indent-")?.toIntOrNull()
    val indent = if (depth != null && depth in 1..32 && token == "wikidict-poem-indent-$depth") depth else 0
    val directions = tokens.filter { it.startsWith("wikidict-poem-dir") }
    val direction = when (directions.singleOrNull()) {
        "wikidict-poem-dir-ltr" -> "ltr"
        "wikidict-poem-dir-rtl" -> "rtl"
        else -> null
    }
    return PoemMetadata(indent, direction)
}

/** Ranges are the actual appended offsets, including lexical bidi isolates and trails. */
internal fun poemParagraphs(text: String, spans: List<Pair<Span, IntRange>>): List<PoemParagraph> = buildList {
    var start = 0
    var marked = false
    var metadata: PoemMetadata? = null
    fun accept(value: PoemMetadata?) {
        marked = marked || value != null
        val next = value ?: PoemMetadata(0, null)
        val previous = metadata
        metadata = if (previous == null) next else PoemMetadata(
            if (previous.indent == next.indent) previous.indent else 0,
            if (previous.direction == next.direction) previous.direction else null)
    }
    fun finish(end: Int) {
        if (marked) {
            val value = checkNotNull(metadata)
            add(PoemParagraph(start, end, value.indent, value.direction))
        }
        start = end
        marked = false
        metadata = null
    }
    for ((span, range) in spans) {
        var value = poemMetadata(span)
        for (offset in range) {
            val character = text[offset]
            if (character == '\n') {
                // Unmarked boundary breaks finish a poem without changing its line metadata.
                if (value != null) accept(value)
                finish(offset + 1)
                // A surviving raw LF resets generated indentation inside this span.
                // An independently annotated following span can supply its own depth.
                value = value?.copy(indent = 0)
            } else if (character !in '\u2066'..'\u2069') {
                accept(value)
            }
        }
    }
    if (start < text.length) finish(text.length)
}


/** The first typed heading may carry the section label's links without changing its identity. */
internal fun sectionHeadingCompanion(section: Section): Block? {
    val block = section.blocks.firstOrNull() ?: return null
    // Blank labels have no header affordance; leave their blocks in the visible body.
    if (section.title.isBlank() || block.kind != "heading" || block.level != section.level) return null
    if (block.spans.any { it.kind == "line_break" && it.trail.isNotEmpty() }) return null
    if (block.spans.none { it.kind in setOf("link", "external_link") && it.target.isNotEmpty() &&
            (it.text.isNotEmpty() || it.trail.isNotEmpty()) }) return null
    val label = block.spans.joinToString("") { if (it.kind == "line_break") "\n" else it.text + it.trail }
        .trim(' ', '\t', '\r', '\n', '\u00a0')
    return block.takeIf { label == section.title }
}

/** Presentation-only rows. No source parsing: explicit semantic breaks are layout boundaries. */
data class ReadingRow(val key: String, val heading: Section? = null, val block: Block? = null, val compact: Boolean = false, val sectionKey: String = "", val meaningSection: Boolean = false, val headingBlock: Block? = null)

fun readingRows(sections: List<Section>, media: List<Media> = emptyList()): List<ReadingRow> = buildList {
    val owners = MediaOwners(media)
    sections.forEachIndexed { sectionIndex, section ->
        val sectionKey = "heading-$sectionIndex"
        val meaningSection = section.blocks.any { it.kind == "definition" }
        val headingBlock = sectionHeadingCompanion(section)
        add(ReadingRow(sectionKey, heading = section, meaningSection = meaningSection, headingBlock = headingBlock))
        section.blocks.forEachIndexed { blockIndex, original ->
            if (blockIndex == 0 && headingBlock != null) return@forEachIndexed
            val block = compactBlock(original)
            val key = "block-$sectionIndex-$blockIndex"
            if (block.kind == "blank" || (block.table == null && block.kind != "rule" && block.spans.isEmpty())) return@forEachIndexed
            // A caption owns one inline media control across all of its typed lines.
            // Splitting its paragraph would append that control to every resulting row.
            if (block.kind != "paragraph" || block.spans.size < 80 || block.spans.none { it.kind == "line_break" } || block.spans.any {
                    it.hasClassToken("wikidict-poem") ||
                        owners.file(it) != null
                }) {
                add(ReadingRow(key, block = block, sectionKey = sectionKey, meaningSection = meaningSection))
            } else {
                var line = ArrayList<Span>()
                var part = 0
                for (span in block.spans) {
                    if (span.kind == "line_break") {
                        if (line.any { it.text.isNotBlank() || it.trail.isNotBlank() }) add(ReadingRow("$key-${part++}", block = block.copy(spans = line), compact = true, sectionKey = sectionKey, meaningSection = meaningSection))
                        line = ArrayList()
                        if (span.trail.isNotEmpty()) line.add(Span("text", span.trail))
                    } else line.add(span)
                }
                if (line.isNotEmpty()) add(ReadingRow("$key-$part", block = block.copy(spans = line), compact = true, sectionKey = sectionKey, meaningSection = meaningSection))
            }
        }
    }
}

/** Fold a section's own prose, keeping child parts of speech and definitions reachable. */
fun visibleReadingRows(rows: List<ReadingRow>, folded: Set<String>): List<ReadingRow> {
    var hideBody = false
    var canFold = false
    return rows.filter { row ->
        if (row.heading != null) {
            // Blank labels have no heading or details toggle in EntryView.
            canFold = row.heading.title.isNotBlank()
            hideBody = canFold && row.key in folded
            true
        } else !hideBody && !(canFold && row.meaningSection && row.block?.kind != "definition" && row.sectionKey + "-details" in folded)
    }
}


fun initiallyFolded(row: ReadingRow, settings: AppSettings): Boolean {
    val section = row.heading ?: return false
    if (section.title.isBlank()) return false
    return when {
        section.title.startsWith("Pronunciation", true) -> settings.collapsePronunciation
        section.title.startsWith("Etymology", true) -> settings.collapseEtymology
        row.meaningSection -> false
        else -> settings.collapseOtherSections
    }
}

/** Compact ordinary spacing; compiled poem and literal preformatted spacing is semantic. */
fun compactSpans(spans: List<Span>): List<Span> {
    val trimmed = spans.dropWhile { !it.hasClassToken("wikidict-poem") && it.text.isBlank() && it.trail.isBlank() }
        .dropLastWhile { !it.hasClassToken("wikidict-poem") && it.text.isBlank() && it.trail.isBlank() }
    val result = ArrayList<Span>(trimmed.size)
    for (span in trimmed) {
        if (!span.hasClassToken("wikidict-poem") && span.kind == "line_break" && result.lastOrNull()?.kind == "line_break") continue
        if (!span.hasClassToken("wikidict-poem") && span.kind != "line_break" && span.text.isBlank() && span.trail.isBlank() && result.lastOrNull()?.kind == "line_break") continue
        result.add(span)
    }
    return if (result == spans) spans else result
}
private fun compactBlock(block: Block): Block {
    if (block.kind == "preformatted") return block
    val spans = compactSpans(block.spans)
    val table = block.table?.let { t -> t.copy(caption = compactSpans(t.caption), rows = t.rows.map { row -> row.map { cell -> cell.copy(spans = compactSpans(cell.spans)) } }) }
    return if (spans === block.spans && table == null) block else block.copy(spans = spans, table = table)
}

/** Labels come from compiled structure; ordered lists do not become dictionary senses. */
internal fun blockPrefix(block: Block): String = when (block.kind) {
    "definition" -> if (block.number.isNotBlank()) "${block.number.padStart(2, '0')}" else "•"
    "example", "quotation" -> "│ "
    "list_item" -> if (block.number.isNotBlank()) "${block.number}. " else "• "
    "list_detail" -> "↳ "
    else -> ""
}

/** Shared nesting indentation for tables and ordinary text/list blocks. */
internal fun blockIndentDp(block: Block): Int = (block.depth - 1).coerceIn(0, 8) * 7

/** Same-entry section links match compiled headings, with the usual underscore spelling. */
internal fun sectionScrollKey(entry: Entry, target: String): String? {
    if (!target.startsWith("#") || target.length == 1) return null
    val heading = target.substring(1).replace('_', ' ')
    return entry.readingRows.firstOrNull { it.heading?.title == heading }?.key
}

/** Match only actual compiled reference identities; no source or fragment interpretation. */
internal fun referenceScrollIndex(entry: Entry, target: String, folded: Set<String>): Int? {
    val referenceIndex = entry.references.indexOfFirst { target == "#reference-${it.number}" }
    if (referenceIndex < 0) return null
    return 1 + (if (entry.preamble.isEmpty()) 0 else 1) +
        visibleReadingRows(entry.readingRows, folded).size + 1 + referenceIndex
}

internal fun referenceLabel(reference: Reference): String =
    if (reference.group.isBlank()) "[${reference.groupNumber}]" else "[${reference.group} ${reference.groupNumber}]"

/** Apply only an explicit, well-formed language tag; never infer a device locale. */
internal fun spanLanguageTag(language: String): String? {
    if (language.isEmpty()) return null
    return try {
        java.util.Locale.Builder().setLanguageTag(language).build().toLanguageTag()
    } catch (_: java.util.IllformedLocaleException) {
        null
    }
}
