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

internal fun legacyEmbeddedImageCaptions(entry: Entry): Map<String, Set<String>> {
    if (entry.media.isEmpty()) return emptyMap()
    val captions = linkedMapOf<String, MutableSet<String>>()
    val owners = MediaOwners(entry.media)
    fun include(spans: List<Span>) {
        val visible = spans.filter { it.image == null }
        owners.embedded(visible).filter { it.kind == "image" }.forEach { media ->
            val caption = textOf(visible.filter { owners.file(it) == media.file })
            val values = captions.getOrPut(media.file) { linkedSetOf() }
            if (caption.isNotEmpty()) values.add(caption)
        }
    }
    include(entry.displayTitle); include(entry.preamble)
    entry.sections.forEach { section -> section.blocks.forEach { block -> block.visitSpanRuns { spans, _ -> include(spans) } } }
    entry.references.forEach { reference -> reference.visitSpanRuns { spans, _ -> include(spans) } }
    return captions.mapValues { it.value.toSet() }
}

/** Unframed descriptions are alt/tooltip, not visible captions. A different
 * catalogue caption remains visible without repeating the already-inline asset. */
internal fun distinctTypedImageCaption(entry: Entry, media: Media): Boolean {
    if (media.kind != "image") return false
    val caption = media.caption.replace(compiledClassWhitespace, " ").trim().takeIf { it.isNotEmpty() && it != media.file } ?: return false
    if (caption in entry.legacyImageCaptions[media.file].orEmpty()) return false
    val occurrences = entry.inlineImages.filter { it.file == media.file }
    fun normalized(value: String?) = value?.replace(compiledClassWhitespace, " ")?.trim()
    return occurrences.isNotEmpty() && occurrences.none { normalized(it.alt) == caption || normalized(it.tooltip) == caption }
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


internal fun sectionHeadingLabel(section: Section, language: String?, richHeading: Block?): String =
    if (richHeading == null && section.title == language && section.anchor.isEmpty() && section.anchorFallback.isEmpty())
        "Overview" else section.title

internal fun sectionInContents(section: Section, language: String?): Boolean =
    section.title.isNotBlank() && (section.title != language || section.anchor.isNotEmpty() || section.anchorFallback.isNotEmpty())

internal fun sectionHeadingVisible(section: Section, language: String?): Boolean =
    sectionInContents(section, language) || (section.title.isNotBlank() && section.blocks.any { it.kind != "blank" })

/** The first typed heading may carry actions, span presentation, or explicit nesting metadata. */
internal fun sectionHeadingCompanion(section: Section): Block? {
    val block = section.blocks.firstOrNull() ?: return null
    // Blank labels have no header affordance; leave their blocks in the visible body.
    if (section.title.isBlank() || block.kind != "heading" || block.level != section.level) return null
    if (block.spans.any { it.kind == "line_break" && it.trail.isNotEmpty() }) return null
    val nestedHeading = block.depth > 0 && block.listPath.isNotBlank()
    if (!nestedHeading && block.spans.none { it.image != null || (it.explanation.isNotEmpty() ||
            (it.kind in setOf("link", "external_link") && it.target.isNotEmpty()) ||
            (it.kind == "text" && it.text.isNotEmpty() && it.target.isEmpty() &&
                (it.bold || it.italic || it.code || it.small || it.superscript || it.subscript ||
                    it.strike || it.underline || it.foreground != null || it.background != null || it.classes.isNotEmpty() ||
                    it.language.isNotEmpty() || it.direction.isNotEmpty() || it.role != "normal"))) &&
            (it.text.isNotEmpty() || it.trail.isNotEmpty()) }) return null
    val label = block.spans.joinToString("") { if (it.kind == "line_break") "\n" else it.text + it.trail }
        .trim(' ', '\t', '\r', '\n', '\u00a0')
    return block.takeIf { label == section.title }
}

/** Presentation-only rows. No source parsing: explicit semantic breaks are layout boundaries. */
data class ReadingRow(val key: String, val heading: Section? = null, val block: Block? = null, val compact: Boolean = false, val sectionKey: String = "", val meaningSection: Boolean = false, val headingBlock: Block? = null, val etymologySection: Boolean = false)

fun readingRows(sections: List<Section>, media: List<Media> = emptyList(), etymologySections: Set<Int> = emptySet()): List<ReadingRow> = buildList {
    val owners = MediaOwners(media)
    sections.forEachIndexed { sectionIndex, section ->
        val sectionKey = "heading-$sectionIndex"
        val meaningSection = section.blocks.any { it.kind == "definition" }
        val headingBlock = sectionHeadingCompanion(section)
        add(ReadingRow(sectionKey, heading = section, meaningSection = meaningSection, headingBlock = headingBlock,
            etymologySection = sectionIndex in etymologySections))
        section.blocks.forEachIndexed { blockIndex, original ->
            if (blockIndex == 0 && headingBlock != null) return@forEachIndexed
            val block = compactBlock(original)
            val key = "block-$sectionIndex-$blockIndex"
            val authoredList = block.listPath.isNotEmpty() && block.kind in
                setOf("definition", "example", "quotation", "list_item", "list_detail", "term", "indent")
            if (block.kind == "blank" || (block.table == null && block.kind != "rule" && block.spans.isEmpty() && !authoredList && !(block.kind == "heading" && (block.anchor.isNotEmpty() || block.anchorFallback.isNotEmpty())))) return@forEachIndexed
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
                        if (line.any { it.text.isNotBlank() || it.trail.isNotBlank() || it.hasPaintedInlineContent() }) add(ReadingRow("$key-${part++}", block = block.copy(spans = line), compact = true, sectionKey = sectionKey, meaningSection = meaningSection))
                        line = ArrayList()
                        if (span.trail.isNotEmpty()) line.add(Span("text", span.trail, explanation = span.explanation, background = span.background))
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


/** Offer explicit access to body text when no recognized definitions guide initial folding. */
internal fun foldedEntryTextSections(rows: List<ReadingRow>, folded: Set<String>): List<String> {
    if (rows.any { it.meaningSection }) return emptyList()
    val namedSections = rows.filter { it.heading?.title?.isNotBlank() == true }.map { it.key }.toSet()
    return rows.asSequence().filter { it.block != null && it.sectionKey in namedSections && it.sectionKey in folded }
        .map { it.sectionKey }.distinct().toList()
}

fun initiallyFolded(row: ReadingRow, settings: AppSettings): Boolean {
    val section = row.heading ?: return false
    if (section.title.isBlank()) return false
    return when {
        row.etymologySection -> settings.collapseEtymology
        section.title.startsWith("Pronunciation", true) -> settings.collapsePronunciation
        section.title.startsWith("Etymology", true) -> settings.collapseEtymology
        row.meaningSection -> false
        else -> settings.collapseOtherSections
    }
}

private fun Span.hasPaintedInlineContent(): Boolean = image != null || (background != null &&
    ((kind != "line_break" && text.any { it != '\n' }) || trail.any { it != '\n' }))

/** Compact ordinary spacing; compiled poem and literal preformatted spacing is semantic. */
fun compactSpans(spans: List<Span>): List<Span> {
    val trimmed = spans.dropWhile { !it.hasClassToken("wikidict-poem") && !it.hasPaintedInlineContent() && it.text.isBlank() && it.trail.isBlank() }
        .dropLastWhile { !it.hasClassToken("wikidict-poem") && !it.hasPaintedInlineContent() && it.text.isBlank() && it.trail.isBlank() }
    val result = ArrayList<Span>(trimmed.size)
    for (span in trimmed) {
        if (!span.hasClassToken("wikidict-poem") && !span.hasPaintedInlineContent() && span.kind == "line_break" && result.lastOrNull()?.kind == "line_break") continue
        if (!span.hasClassToken("wikidict-poem") && !span.hasPaintedInlineContent() && span.kind != "line_break" && span.text.isBlank() && span.trail.isBlank() && result.lastOrNull()?.kind == "line_break") continue
        result.add(span)
    }
    return if (result == spans) spans else result
}
private fun compactBlock(block: Block): Block {
    if (block.kind == "preformatted") return block
    val spans = compactSpans(block.spans)
    fun compactTable(table: Table): Table = table.copy(caption = compactSpans(table.caption),
        rows = table.rows.map { row -> row.map { cell -> cell.copy(spans = compactSpans(cell.spans),
            nestedTable = cell.nestedTable?.let(::compactTable), blocks = cell.blocks?.map(::compactBlock)) } })
    val table = block.table?.let(::compactTable)
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

/** Headings retain their full structural depth; other blocks keep their existing list offset. */
internal fun blockIndentDp(block: Block): Int =
    (if (block.kind == "heading") block.depth else block.depth - 1).coerceIn(0, 8) * 7

/** A nested destination is owned by one lazy row and an authored-index path, never pixels. */
internal data class HeadingDestination(val rowKey: String, val path: String?, val compiledId: Boolean,
    val referenceIndex: Int? = null)
private data class HeadingCandidate(val destination: HeadingDestination, val anchor: String, val fallback: String, val label: String)
internal fun headingDestination(entry: Entry, target: String): HeadingDestination? {
    if (!target.startsWith("#") || target.length == 1) return null
    val headings = mutableListOf<HeadingCandidate>()
    fun includeContent(rowKey: String, blocks: List<Pair<Block, String>>, referenceIndex: Int? = null) {
        lateinit var includeBlock: (Block, String, Boolean) -> Unit
        fun includeTable(table: Table, path: String) {
            var index = 0
            table.rows.forEach { cells -> cells.forEach { cell ->
                val cellPath = "$path/cell-${index++}"
                val content = cell.blocks
                if (content != null) content.forEachIndexed { blockIndex, block -> includeBlock(block, "$cellPath/block-$blockIndex", true) }
                else cell.nestedTable?.let { includeTable(it, "$cellPath/nested") }
            } }
        }
        includeBlock = { block, path, nested ->
            if (block.kind == "heading") headings.add(HeadingCandidate(HeadingDestination(rowKey, path.takeIf { nested },
                block.anchor.isNotEmpty() || block.anchorFallback.isNotEmpty(), referenceIndex), block.anchor, block.anchorFallback, textOf(block.spans)))
            block.table?.let { includeTable(it, "$path/table") }
        }
        blocks.forEach { (block, path) -> includeBlock(block, path, referenceIndex != null) }
    }
    entry.readingRows.forEach { row ->
        row.heading?.let { heading -> headings.add(HeadingCandidate(HeadingDestination(row.key, null,
            heading.anchor.isNotEmpty() || heading.anchorFallback.isNotEmpty()), heading.anchor, heading.anchorFallback, heading.title)) }
        row.block?.let { includeContent(row.key, listOf(it to row.key)) }
    }
    entry.references.forEachIndexed { index, reference ->
        reference.blocks?.let { blocks ->
            val key = "reference-${reference.number}"
            includeContent(key, blocks.mapIndexed { blockIndex, block -> block to "$key/block-$blockIndex" }, index)
        }
    }
    val fragment = target.substring(1)
    fun matches(value: String) = headings.filter { (it.anchor.isNotEmpty() && it.anchor == value) || (it.fallback.isNotEmpty() && it.fallback == value) }
    val exact = matches(fragment)
    if (exact.isNotEmpty()) return exact.singleOrNull()?.destination
    val spaced = matches(fragment.replace(' ', '_'))
    if (spaced.isNotEmpty()) return spaced.singleOrNull()?.destination
    return headings.filter { it.label == fragment.replace('_', ' ') }.singleOrNull()
        ?.takeIf { it.anchor.isEmpty() && it.fallback.isEmpty() }?.destination
}
/** Compatibility for callers interested only in the owning lazy row. */
internal fun headingScrollKey(entry: Entry, target: String): String? = headingDestination(entry, target)?.rowKey

/** Match only actual compiled reference identities; no source or fragment interpretation. */
/** Items before the section rows: title/actions, visible explanations and preamble. */
internal fun entryReadingStartIndex(entry: Entry, folded: Set<String>): Int =
    1 + (if ("abbreviations" in folded) 0 else entry.abbreviations.size) +
        if (entry.preamble.isEmpty()) 0 else 1

/** An empty leaf duplicating the generated references group has no separate body. */
internal fun metadataReferenceHeadingKey(entry: Entry): String? {
    if (entry.references.isEmpty()) return null
    val index = entry.sections.indices.singleOrNull { index ->
        val section = entry.sections[index]
        section.title == "References" && section.blocks.isEmpty() &&
            (entry.sections.getOrNull(index + 1)?.level ?: 0) <= section.level
    }
    return index?.let { "heading-$it" }
}

internal fun visibleEntryReadingRows(entry: Entry, folded: Set<String>): List<ReadingRow> {
    val placeholder = metadataReferenceHeadingKey(entry)
    return visibleReadingRows(entry.readingRows, folded).filterNot { it.key == placeholder }
}

internal fun metadataReferencesStartIndex(entry: Entry, folded: Set<String>): Int =
    entryReadingStartIndex(entry, folded) + visibleEntryReadingRows(entry, folded).size

internal fun referenceScrollIndex(entry: Entry, target: String, folded: Set<String>): Int? {
    val referenceIndex = entry.references.indexOfFirst { it.kind == ReferenceKind.Note && target == "#reference-${it.number}" }
    if (referenceIndex < 0) return null
    return metadataReferencesStartIndex(entry, folded) + 1 + referenceIndex
}

internal fun referenceLabel(reference: Reference): String? = when {
    reference.kind == ReferenceKind.Fragment -> null
    reference.group.isBlank() -> "[${reference.groupNumber}]"
    else -> "[${reference.group} ${reference.groupNumber}]"
}

/** Apply only an explicit, well-formed language tag; never infer a device locale. */
internal fun spanLanguageTag(language: String): String? {
    if (language.isEmpty()) return null
    return try {
        java.util.Locale.Builder().setLanguageTag(language).build().toLanguageTag()
    } catch (_: java.util.IllformedLocaleException) {
        null
    }
}
