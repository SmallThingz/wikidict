package app.smallthingz.dict

/** Presentation-only rows. No source parsing: explicit semantic breaks are layout boundaries. */
data class ReadingRow(val key: String, val heading: Section? = null, val block: Block? = null, val compact: Boolean = false, val sectionKey: String = "", val meaningSection: Boolean = false)

fun readingRows(sections: List<Section>): List<ReadingRow> = buildList {
    sections.forEachIndexed { sectionIndex, section ->
        val sectionKey = "heading-$sectionIndex"
        val meaningSection = section.blocks.any { it.kind == "definition" }
        add(ReadingRow(sectionKey, heading = section, meaningSection = meaningSection))
        section.blocks.forEachIndexed { blockIndex, original ->
            val block = compactBlock(original)
            val key = "block-$sectionIndex-$blockIndex"
            if (block.kind == "blank" || (block.table == null && block.kind != "rule" && block.spans.isEmpty())) return@forEachIndexed
            if (block.kind != "paragraph" || block.spans.size < 80 || block.spans.none { it.kind == "line_break" }) {
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
    return rows.filter { row ->
        if (row.heading != null) { hideBody = row.key in folded; true } else !hideBody && !(row.meaningSection && row.block?.kind != "definition" && row.sectionKey + "-details" in folded)
    }
}


fun initiallyFolded(row: ReadingRow, settings: AppSettings): Boolean {
    val section = row.heading ?: return false
    return when {
        section.title.startsWith("Pronunciation", true) -> settings.collapsePronunciation
        section.title.startsWith("Etymology", true) -> settings.collapseEtymology
        row.meaningSection -> false
        else -> settings.collapseOtherSections
    }
}

/** Compact semantic spacing; never modify literal preformatted content. */
fun compactSpans(spans: List<Span>): List<Span> {
    val trimmed = spans.dropWhile { it.text.isBlank() && it.trail.isBlank() }
        .dropLastWhile { it.text.isBlank() && it.trail.isBlank() }
    val result = ArrayList<Span>(trimmed.size)
    for (span in trimmed) {
        if (span.kind == "line_break" && result.lastOrNull()?.kind == "line_break") continue
        if (span.kind != "line_break" && span.text.isBlank() && span.trail.isBlank() && result.lastOrNull()?.kind == "line_break") continue
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

/** Match only actual compiled reference identities; no source or fragment interpretation. */
internal fun referenceScrollIndex(entry: Entry, target: String, folded: Set<String>): Int? {
    val referenceIndex = entry.references.indexOfFirst { target == "#reference-${it.number}" }
    if (referenceIndex < 0) return null
    return 1 + (if (entry.preamble.isEmpty()) 0 else 1) +
        visibleReadingRows(entry.readingRows, folded).size + 1 + referenceIndex
}

internal fun referenceLabel(reference: Reference): String =
    if (reference.group.isBlank()) "[${reference.groupNumber}]" else "[${reference.group} ${reference.groupNumber}]"
