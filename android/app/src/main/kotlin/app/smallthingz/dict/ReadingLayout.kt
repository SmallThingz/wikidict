package app.smallthingz.dict


private val compiledClassWhitespace = Regex("\\s+")
internal fun Span.hasClassToken(token: String): Boolean =
    classes.split(compiledClassWhitespace).any { it == token }
internal fun Span.withoutClassToken(token: String): Span =
    copy(classes = classes.split(compiledClassWhitespace).filter { it.isNotEmpty() && it != token }.joinToString(" "),
        audioControl = if (token == "wikidict-media") null else audioControl)

/** A typed source AUDIO owns one control occurrence, independently of its cached asset. */
internal data class EmbeddedMediaControl(val media: Media, val sourceIndex: Int?, val audioControl: AudioControl?,
    val sourceDirection: String = "") {
    init {
        require((sourceIndex != null) == (audioControl != null))
        require(audioControl != null || sourceDirection.isEmpty())
    }
}

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

    /** The existing catalog index authenticates annotation ownership, including legacy target fallback. */
    fun media(span: Span): Media? = file(span)?.let(files::get)

    fun embedded(spans: List<Span>): List<Media> =
        spans.mapNotNull { file(it)?.let(files::get) }.distinctBy { it.file }

    /** Legacy caption fragments still share a file control. Explicit AUDIO owners never do. */
    fun embeddedControls(spans: List<Span>): List<EmbeddedMediaControl> {
        val legacyFiles = hashSetOf<String>()
        return buildList {
            spans.forEachIndexed { index, span ->
                val media = media(span)
                val control = span.audioControl
                if (control != null) {
                    require(media?.kind == "audio") { "Audio control owner has no compiled audio asset" }
                    add(EmbeddedMediaControl(checkNotNull(media), index, control, span.direction))
                } else if (media != null && legacyFiles.add(media.file)) {
                    add(EmbeddedMediaControl(media, null, null))
                }
            }
        }
    }
}

/** Resolve every stacked control against original content C; allocation never becomes a new percentage basis. */
internal fun embeddedMediaSlotWidth(controls: List<EmbeddedMediaControl>, containingWidth: Int,
    left: Float, right: Float, density: Float, normalBodyPixels: Float, overflowOwned: Boolean = false): Int {
    if (containingWidth !in 0..TablePixelLimit || !left.isFinite() || !right.isFinite() || left < 0f || right < 0f)
        throw UnsupportedFloatLayout("Invalid audio containing allocation")
    val contentWidth = (containingWidth.toDouble() - left - right).coerceAtLeast(0.0).toFloat()
    val largest = controls.mapNotNull { occurrence -> occurrence.audioControl?.let {
        audioControlWidthPixels(it, contentWidth, density, normalBodyPixels)
    } }.maxOrNull() ?: return containingWidth
    // The native edge is Float; do not turn a rounded fitting edge back into a Double overflow.
    val allocation = maxOf(containingWidth.toFloat(), (left.toDouble() + largest + right).toFloat())
    if (!allocation.isFinite() || allocation > TablePixelLimit)
        throw UnsupportedFloatLayout("Audio allocation exceeds the native measurement range")
    if (!overflowOwned && allocation > containingWidth)
        throw UnsupportedFloatLayout("Audio overflow requires a represented document owner")
    return kotlin.math.ceil(allocation.toDouble()).toInt()
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
    section.headingStyle != null || sectionInContents(section, language) ||
        (section.title.isNotBlank() && section.blocks.any { it.kind != "blank" })

/** The first typed heading may carry actions, span presentation, or explicit nesting metadata. */
internal fun sectionHeadingCompanion(section: Section): Block? {
    // Typed headings validate this exact companion, including a plain or whitespace-only title.
    if (section.headingStyle != null) return section.blocks.first()
    val block = section.blocks.firstOrNull() ?: return null
    // Blank labels have no header affordance; leave their blocks in the visible body.
    if (section.title.isBlank() || block.kind != "heading" || block.level != section.level) return null
    if (block.spans.hasNativeInlineGroups()) return block.takeIf { rubyFallbackText(it.spans) == section.title }
    if (block.spans.any { it.kind == "line_break" && it.trail.isNotEmpty() }) return null
    val nestedHeading = block.depth > 0 && block.listPath.isNotBlank()
    if (!nestedHeading && block.spans.none { it.image != null || (it.tooltip != null || it.explanation.isNotEmpty() ||
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
data class ReadingRow(val key: String, val heading: Section? = null, val block: Block? = null, val compact: Boolean = false, val sectionKey: String = "", val meaningSection: Boolean = false, val headingBlock: Block? = null, val etymologySection: Boolean = false, val reference: Reference? = null, val referenceIndex: Int? = null, val referenceBatch: ReferenceBatchPlacement? = null)

fun readingRows(sections: List<Section>, media: List<Media> = emptyList(), etymologySections: Set<Int> = emptySet(),
    bodyAdjoining: BodyAdjoiningPolicy? = null, references: List<Reference> = emptyList(),
    referenceBatches: List<ReferenceBatchPlacement>? = null): List<ReadingRow> = buildList {
    val owners = MediaOwners(media)
    val authoredBody = bodyAdjoining != null || sections.any { it.headingStyle != null }
    var nextBatch = 0
    sections.forEachIndexed { sectionIndex, section ->
        val sectionKey = "heading-$sectionIndex"
        val meaningSection = section.blocks.any { it.kind == "definition" }
        val headingBlock = sectionHeadingCompanion(section)
        fun appendBatches(boundary: Int) {
            while (referenceBatches != null && nextBatch < referenceBatches.size) {
                val batch = referenceBatches[nextBatch]
                if (batch.sectionIndex != sectionIndex || batch.beforeBlockIndex != boundary) break
                if (batch.layout != null) {
                    add(ReadingRow("reference-batch-$nextBatch", sectionKey = sectionKey,
                        meaningSection = meaningSection, referenceBatch = batch))
                } else batch.referenceIndices.forEach { index ->
                    val reference = references[index]
                    add(ReadingRow("reference-item-$index", sectionKey = sectionKey,
                        meaningSection = meaningSection, reference = reference, referenceIndex = index))
                }
                nextBatch++
            }
        }
        // A rich companion is actual block zero; compiled layout batches precede it.
        // Metadata-only headings and all legacy null-layout records retain their ordering.
        if (headingBlock != null && referenceBatches != null) {
            var boundaryBatch = nextBatch
            var hasLayout = false
            while (boundaryBatch < referenceBatches.size) {
                val batch = referenceBatches[boundaryBatch]
                if (batch.sectionIndex != sectionIndex || batch.beforeBlockIndex != 0) break
                if (batch.layout != null) { hasLayout = true; break }
                boundaryBatch++
            }
            if (hasLayout) appendBatches(0)
        }
        add(ReadingRow(sectionKey, heading = section, meaningSection = meaningSection, headingBlock = headingBlock,
            etymologySection = sectionIndex in etymologySections))
        section.blocks.forEachIndexed { blockIndex, original ->
            appendBatches(blockIndex)
            if (blockIndex == 0 && headingBlock != null) return@forEachIndexed
            val key = "block-$sectionIndex-$blockIndex"
            if (original.descriptionBody != null || bodyAdjoining == BodyAdjoiningPolicy.Ordinary ||
                (authoredBody && sectionIndex == 0 && section.isAuthoredBodyPrefix()) ||
                (original.spans.hasAuthoredFontFamily() || original.spans.hasNativeInlineGroups())) {
                // This owner consumes source block boundaries, including empty or unsupported ones.
                add(ReadingRow(key, block = original, sectionKey = sectionKey, meaningSection = meaningSection))
                return@forEachIndexed
            }
            val block = compactBlock(original)
            val authoredList = block.listPath.isNotEmpty() && block.kind in
                setOf("definition", "example", "quotation", "list_item", "list_detail", "term", "indent")
            if (block.kind == "blank" || (block.style == null && block.table == null && block.figure == null && block.flow == null && block.container == null && block.kind != "rule" && block.spans.isEmpty() && !authoredList && !(block.kind == "heading" && (block.anchor.isNotEmpty() || block.anchorFallback.isNotEmpty())))) return@forEachIndexed
            // A caption owns one inline media control across all of its typed lines.
            // Splitting its paragraph would append that control to every resulting row.
            if (block.style != null || block.figure != null || block.flow != null || block.kind != "paragraph" || block.spans.size < 80 || block.spans.none { it.kind == "line_break" } || block.spans.any {
                    it.inlineStyle != null || it.hasClassToken("wikidict-poem") ||
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
                        if (span.trail.isNotEmpty()) line.add(Span("text", span.trail, explanation = span.explanation, background = span.background, tooltip = span.tooltip))
                    } else line.add(span)
                }
                if (line.isNotEmpty()) add(ReadingRow("$key-$part", block = block.copy(spans = line), compact = true, sectionKey = sectionKey, meaningSection = meaningSection))
            }
        }
        appendBatches(section.blocks.size)
    }
}

/** Fold a section's own prose, keeping child parts of speech and definitions reachable. */
fun visibleReadingRows(rows: List<ReadingRow>, folded: Set<String>): List<ReadingRow> {
    var hideBody = false
    var canFold = false
    val headings = rows.filter { it.heading != null }.associateBy { it.key }
    return rows.filter { row ->
        if (row.heading != null) {
            // Typed headings keep their compiled label, including whitespace.
            canFold = row.heading.headingStyle != null || row.heading.title.isNotBlank()
            hideBody = canFold && row.key in folded
            true
        } else if (row.referenceBatch != null || row.referenceIndex != null) {
            // A boundary-zero batch can precede its own heading, never inheriting the previous section's fold.
            val heading = headings[row.sectionKey]?.heading
            val ownCanFold = heading != null && (heading.headingStyle != null || heading.title.isNotBlank())
            !(ownCanFold && (row.sectionKey in folded || row.meaningSection && row.sectionKey + "-details" in folded))
        } else !hideBody && !(canFold && row.meaningSection && row.block?.kind != "definition" && row.sectionKey + "-details" in folded)
    }
}


/** Offer explicit access to body text when no recognized definitions guide initial folding. */
internal fun foldedEntryTextSections(rows: List<ReadingRow>, folded: Set<String>): List<String> {
    if (rows.any { it.meaningSection }) return emptyList()
    val namedSections = rows.filter { it.heading?.let { heading -> heading.headingStyle != null || heading.title.isNotBlank() } == true }.map { it.key }.toSet()
    return rows.asSequence().filter { it.block != null && it.sectionKey in namedSections && it.sectionKey in folded }
        .map { it.sectionKey }.distinct().toList()
}

fun initiallyFolded(row: ReadingRow, settings: AppSettings): Boolean {
    val section = row.heading ?: return false
    if (section.headingStyle == null && section.title.isBlank()) return false
    return when {
        row.etymologySection -> settings.collapseEtymology
        section.title.startsWith("Pronunciation", true) -> settings.collapsePronunciation
        section.title.startsWith("Etymology", true) -> settings.collapseEtymology
        row.meaningSection -> false
        else -> settings.collapseOtherSections
    }
}

/** Empty metric owners retain their source position without adding any logical character. */
internal fun Span.hasAuthoredInlineMetrics(): Boolean = inlineStyle?.lineHeight != null
internal fun Span.isEmptyInlineMetricOwner(): Boolean = hasAuthoredInlineMetrics() && image == null && ruby == null && inlinePaddingGroup == null && inlineActionGroup == null && inlineBoxGroup == null && clippedAbsolute == null &&
    text.isEmpty() && trail.isEmpty()
internal fun Span.usesInlineDirectionIsolate(): Boolean = direction in listOf("rtl", "ltr", "auto") &&
    !isEmptyInlineMetricOwner()
internal fun Span.isUnsupportedAuthoredWhitespaceOwner(): Boolean = ruby == null && inlinePaddingGroup == null && inlineActionGroup == null && inlineBoxGroup == null && clippedAbsolute == null && inlineStyle != null &&
    (kind in listOf("link", "external_link") || inlineStyle?.cursor != null || inlineStyle?.lineHeight == null) &&
    text.all { it == ' ' || it == '\t' || it == '\r' || it == '\n' }

/** Typed owners retain their original children and surrounding compiled spacing. */
internal fun List<Span>.hasRuby(): Boolean = any { it.ruby != null }
internal fun List<Span>.hasNativeInlineGroups(): Boolean = any { it.ruby != null || it.inlinePaddingGroup != null || it.inlineActionGroup != null || it.inlineBoxGroup != null || it.citationMarker != null || it.clippedAbsolute != null }

/** New family fields preserve the whole compiled inline owner, including its unstyled neighbours. */
internal fun List<Span>.hasAuthoredFontFamily(): Boolean = any { span ->
    span.fontFamily != null ||
        (span.inlineStyle?.lineHeight as? InlineLineHeight.FontRelative)?.font?.fontFamily != null
}

internal fun List<Span>.hasCompiledInlineContent(): Boolean = any {
    it.kind == "line_break" || it.text.isNotEmpty() || it.trail.isNotEmpty() ||
        it.image != null || it.audioControl != null || it.hasAuthoredInlineMetrics() || it.ruby != null || it.inlinePaddingGroup != null || it.inlineActionGroup != null || it.inlineBoxGroup != null || it.clippedAbsolute != null
}

internal enum class LegacySpanFontFamily { Code, Egyptian }
internal fun Span.legacyFontFamily(): LegacySpanFontFamily? = when {
    fontFamily != null -> null
    code -> LegacySpanFontFamily.Code
    hasClassToken("Egyp") -> LegacySpanFontFamily.Egyptian
    else -> null
}

internal fun Section.isAuthoredBodyPrefix(): Boolean = level == 0 && title.isEmpty() &&
    anchor.isEmpty() && anchorFallback.isEmpty() && headingStyle == null && blocks.isNotEmpty()

/** A temporary font probe only: this space is never appended to document text. */
internal fun inlineFontSnapshotSpan(snapshot: InlineFontSnapshot): Span = Span("text", " ",
    language = snapshot.language, classes = snapshot.classes, bold = snapshot.bold, italic = snapshot.italic,
    code = snapshot.code, small = snapshot.small, superscript = snapshot.superscript, subscript = snapshot.subscript,
    role = snapshot.role, fontScale = snapshot.fontScale, fontScaleBasis = snapshot.fontScaleBasis,
    fontFeatures = snapshot.fontFeatures, fontFamily = snapshot.fontFamily,
    inlineStyle = if (snapshot.fontNormalized) InlineTextStyle(fontNormalized = true) else null)

internal fun inlineMetricOwnerSpan(span: Span): Span = span.copy(kind = "text", text = " ", target = "", trail = "",
    direction = "", image = null, ruby = null, inlinePaddingGroup = null, inlineActionGroup = null, inlineBoxGroup = null, clippedAbsolute = null, targetFragment = null, linkPaint = null, underline = false, strike = false,
    citationMarker = null, citationBacklinkWitness = null, audioControl = null,
    inlineStyle = if (span.inlineStyle?.fontNormalized == true) InlineTextStyle(fontNormalized = true) else null)

internal fun tableHasAuthoredInlineStyles(table: Table): Boolean {
    var found = false
    table.visitSpanRuns { spans, _ -> if (spans.hasAuthoredFontFamily() || spans.hasNativeInlineGroups() || spans.any { it.inlineStyle != null }) found = true }
    return found
}

private fun Span.hasPaintedInlineContent(): Boolean = image != null || linkPaint != null || (background != null &&
    ((kind != "line_break" && text.any { it != '\n' }) || trail.any { it != '\n' }))
private fun Span.hasRetainedInlineContent(): Boolean = audioControl != null || hasPaintedInlineContent() || hasAuthoredInlineMetrics() ||
    isUnsupportedAuthoredWhitespaceOwner() || (inlineStyle != null &&
        (text + trail).any { it != ' ' && it != '\t' && it != '\r' && it != '\n' })

/** Compact ordinary spacing; compiled poem and literal preformatted spacing is semantic. */
fun compactSpans(spans: List<Span>): List<Span> {
    if (spans.hasAuthoredFontFamily() || spans.hasNativeInlineGroups()) return spans
    val trimmed = spans.dropWhile { !it.hasClassToken("wikidict-poem") && !it.hasRetainedInlineContent() && it.text.isBlank() && it.trail.isBlank() }
        .dropLastWhile { !it.hasClassToken("wikidict-poem") && !it.hasRetainedInlineContent() && it.text.isBlank() && it.trail.isBlank() }
    val result = ArrayList<Span>(trimmed.size)
    for (span in trimmed) {
        if (!span.hasClassToken("wikidict-poem") && !span.hasRetainedInlineContent() && span.kind == "line_break" && result.lastOrNull()?.kind == "line_break") continue
        if (!span.hasClassToken("wikidict-poem") && !span.hasRetainedInlineContent() && span.kind != "line_break" && span.text.isBlank() && span.trail.isBlank() && result.lastOrNull()?.kind == "line_break") continue
        result.add(span)
    }
    return if (result == spans) spans else result
}
private fun compactBlock(block: Block): Block {
    if (block.kind == "preformatted" || block.figure != null || block.flow != null) return block
    val spans = if (block.style != null) paragraphDisplaySpans(block) else compactSpans(block.spans)
    fun compactTable(table: Table): Table = table.copy(caption = compactSpans(table.caption),
        captionBlocks = table.captionBlocks?.map(::compactBlock),
        rows = table.rows.map { row -> row.map { cell -> cell.copy(spans = compactSpans(cell.spans),
            nestedTable = cell.nestedTable?.let(::compactTable), blocks = cell.blocks?.map(::compactBlock)) } })
    val table = block.table?.let(::compactTable)
    return if (spans === block.spans && table == null) block else block.copy(spans = spans, table = table)
}

/** A styled source box is not split or given a text line just to carry its edges. */
internal fun paragraphDisplaySpans(block: Block): List<Span> {
    if (block.spans.hasAuthoredFontFamily() || block.spans.hasNativeInlineGroups()) return block.spans
    val spans = ordinaryInlineDisplaySpans(block)
    if (block.style == null) return compactSpans(spans)
    fun collapsible(span: Span) = span.kind != "line_break" && !span.hasRetainedInlineContent() &&
        ((span.text.isEmpty() && span.trail.isEmpty()) || (!span.code && !span.hasClassToken("wikidict-poem") &&
            (span.text + span.trail).all { it == ' ' || it == '\t' || it == '\r' || it == '\n' }))
    return spans.dropWhile(::collapsible).dropLastWhile(::collapsible)
}

internal fun paragraphHasContent(block: Block, preserveCompiledText: Boolean = false): Boolean {
    fun inline(spans: List<Span>, owner: Block): Boolean =
        if (preserveCompiledText || spans.hasAuthoredFontFamily() || spans.hasNativeInlineGroups()) spans.hasCompiledInlineContent()
        else spans.any { it.kind == "line_break" } || paragraphDisplaySpans(owner).isNotEmpty()
    fun parts(values: List<FlowPart>): Boolean = values.any { part -> when (part) {
        is FlowPart.Inline -> inline(part.spans, Block("paragraph", 0, part.spans))
        is FlowPart.ImageFigure -> true
        is FlowPart.Scope -> parts(part.scope.parts)
    } }
    return block.figure != null || (block.flow?.let(::parts) ?: inline(block.spans, block))
}

internal data class ParagraphEdges(val top: Float = 0f, val right: Float = 0f,
    val bottom: Float = 0f, val left: Float = 0f) {
    init { require(listOf(top, right, bottom, left).all { it.isFinite() && it >= 0f }) }
}

internal data class ParagraphBox(val margins: ParagraphEdges, val padding: ParagraphEdges,
    val before: Float, val after: Float,
    val hasAuthoredMargins: Boolean = true) {
    init { require(before.isFinite() && before >= 0f && after.isFinite() && after >= 0f) }
    val contentLeft: Float get() = margins.left + padding.left
    val contentRight: Float get() = margins.right + padding.right
}

/** Paragraph edges are source geometry, not font sizes: never apply the font render ceiling. */
internal fun paragraphLengthPixels(value: StyleLength, density: Float, normalBodyFontPixels: Float): Float {
    require(density.isFinite() && density > 0f && normalBodyFontPixels.isFinite() && normalBodyFontPixels >= 0f)
    val pixels = value.value.toDouble() * if (value.unit == StyleLengthUnit.Px) density.toDouble() else normalBodyFontPixels.toDouble()
    if (!pixels.isFinite() || pixels > Int.MAX_VALUE / 4.0)
        throw UnsupportedFloatLayout("Paragraph edge exceeds native coordinate range")
    return pixels.toFloat()
}

/** Reader typography policy: authored margins replace this paragraph's own outside gap. */
internal fun paragraphBox(block: Block, previous: Block?, defaultGap: Float,
    density: Float, normalBodyFontPixels: Float, preserveCompiledText: Boolean = false): ParagraphBox? {
    val style = block.style ?: return null
    require(defaultGap.isFinite() && defaultGap >= 0f)
    fun edges(value: StyleEdges?) = if (value == null) ParagraphEdges() else ParagraphEdges(
        paragraphLengthPixels(value.top, density, normalBodyFontPixels),
        paragraphLengthPixels(value.right, density, normalBodyFontPixels),
        paragraphLengthPixels(value.bottom, density, normalBodyFontPixels),
        paragraphLengthPixels(value.left, density, normalBodyFontPixels))
    val margins = edges(style.margins)
    // Callers pass a predecessor only within the same block-flow container. A table/list/heading
    // breaks adjacency; cell/reference/container spacing is never converted to a source margin.
    val previousBottom = previous?.takeIf { it.kind == "paragraph" }?.style?.margins?.bottom
        ?.let { paragraphLengthPixels(it, density, normalBodyFontPixels) } ?: 0f
    val before = if (style.margins != null) (margins.top - previousBottom).coerceAtLeast(0f) else 0f
    val after = if (style.margins != null) margins.bottom
        else if (!paragraphHasContent(block, preserveCompiledText)) 0f else defaultGap
    return ParagraphBox(margins, edges(style.padding), before, after,
        hasAuthoredMargins = style.margins != null)
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
internal enum class HeadingAnchorKind { Primary, Fallback }
internal data class HeadingAnchorSelection(val id: String, val kind: HeadingAnchorKind, val revealTop: StyleLength?)
internal data class HeadingDestination(val rowKey: String, val path: String?, val compiledId: Boolean,
    val referenceIndex: Int? = null, val anchorMatch: HeadingAnchorSelection? = null,
    val rowsHiddenMaxWidthPx: Long? = null, val nativeNavigationUnavailable: Boolean = false)
private data class HeadingCandidate(val destination: HeadingDestination, val anchor: String, val fallback: String,
    val label: String, val reveal: HeadingAnchorReveal? = null)

/** Only the selected source outset participates; text zoom and UI insets are not source lengths. */
internal fun headingRevealScrollDelta(targetTop: Float, viewportTop: Float, outset: StyleLength,
    density: Float): Float? {
    if (!targetTop.isFinite() || !viewportTop.isFinite() || !density.isFinite() || density <= 0f ||
        outset.unit != StyleLengthUnit.Px) return null
    val pixels = outset.value.toDouble() * density
    val delta = targetTop.toDouble() - viewportTop - pixels
    return delta.toFloat().takeIf { pixels.isFinite() && it.isFinite() }
}
internal fun headingDestination(entry: Entry, target: String): HeadingDestination? {
    if (!target.startsWith("#") || target.length == 1) return null
    val headings = mutableListOf<HeadingCandidate>()
    fun includeContent(rowKey: String, blocks: List<Pair<Block, String>>, referenceIndex: Int? = null) {
        lateinit var includeBlock: (Block, String, Boolean, Boolean, Long?, Boolean) -> Unit
        fun includeTable(table: Table, path: String, disclosureAncestor: Boolean, inheritedRowsHidden: Long?, rowPolicyAncestor: Boolean) {
            val rowPolicyOwner = rowPolicyAncestor || table.rowsHiddenMaxWidthPx != null
            val extendedOwner = disclosureAncestor || table.rowsHiddenMaxWidthPx != null
            val rowsHidden = table.rowsHiddenMaxWidthPx?.let { maxOf(it, inheritedRowsHidden ?: it) }
                ?: inheritedRowsHidden
            table.captionBlocks?.forEachIndexed { index, block ->
                if (extendedOwner || block.hasContainerDisclosure() || block.hasTableRowVisibilityPolicy())
                    includeBlock(block, "$path/caption/block-$index", true, extendedOwner, inheritedRowsHidden, rowPolicyOwner)
            }
            var index = 0
            table.rows.forEach { cells -> cells.forEach { cell ->
                val cellPath = "$path/cell-${index++}"
                val content = cell.blocks
                if (content != null) content.forEachIndexed { blockIndex, block -> includeBlock(block, "$cellPath/block-$blockIndex", true, extendedOwner, rowsHidden, rowPolicyOwner) }
                else cell.nestedTable?.let { includeTable(it, "$cellPath/nested", extendedOwner, rowsHidden, rowPolicyOwner) }
            } }
        }
        includeBlock = { block, path, nested, disclosureAncestor, rowsHidden, rowPolicyAncestor ->
            if (block.kind == "heading") headings.add(HeadingCandidate(HeadingDestination(rowKey, path.takeIf { nested },
                block.anchor.isNotEmpty() || block.anchorFallback.isNotEmpty(), referenceIndex,
                rowsHiddenMaxWidthPx = rowsHidden), block.anchor, block.anchorFallback, textOf(block.spans)))
            val container = block.contentBox
            if (container != null && (disclosureAncestor || block.hasContainerDisclosure() || block.hasTableRowVisibilityPolicy())) {
                // Only a disclosure or row-policy source owner opens this path. Container
                // heading validity and original Table/cell paths remain unchanged.
                container.blocks.forEachIndexed { index, child ->
                    includeBlock(child, "$path/container/block-$index", true, true, rowsHidden, rowPolicyAncestor)
                }
            }
            block.table?.let { includeTable(it, "$path/table", disclosureAncestor, rowsHidden, rowPolicyAncestor) }
            if ((block.figure != null || block.flow != null) &&
                (rowPolicyAncestor || block.hasTableRowVisibilityPolicy())) {
                // Figure caption headings are source identities, but the current caption
                // renderer lowers them to paragraph text without a heading reveal path.
                // Keep them in this new policy's namespace as explicit refusal witnesses.
                val rowPolicies = java.util.IdentityHashMap<Block, Long>()
                val visitor = PresentationSpanVisitor { _, _ -> }
                visitor.onTable = { table, tableDepth, contentDepth -> table.rowsHiddenMaxWidthPx?.let { maximum ->
                    val rows = PresentationSpanVisitor { _, _ -> }.apply { onBlock = { source ->
                        if (source.kind == "heading") rowPolicies[source] = maxOf(maximum, rowPolicies[source] ?: maximum)
                    } }
                    table.rows.forEach { cells -> cells.forEach { cell -> when {
                        cell.blocks != null -> rows.blocks(cell.blocks, tableDepth, contentDepth)
                        cell.nestedTable != null -> rows.table(cell.nestedTable, tableDepth + 1, contentDepth)
                        else -> rows.spans(cell.spans, contentDepth = contentDepth)
                    } } }
                } }
                visitor.onBlock = { source -> if (source !== block && source.kind == "heading") {
                    val maximum = rowPolicies[source]?.let { maxOf(it, rowsHidden ?: it) } ?: rowsHidden
                    headings.add(HeadingCandidate(HeadingDestination(rowKey, null,
                        source.anchor.isNotEmpty() || source.anchorFallback.isNotEmpty(), referenceIndex,
                        rowsHiddenMaxWidthPx = maximum, nativeNavigationUnavailable = true),
                        source.anchor, source.anchorFallback, textOf(source.spans)))
                } }
                visitor.block(block)
            }
        }
        blocks.forEach { (block, path) -> includeBlock(block, path, referenceIndex != null, false, null, false) }
    }
    entry.readingRows.forEach { row ->
        row.heading?.let { heading -> headings.add(HeadingCandidate(HeadingDestination(row.key, null,
            heading.anchor.isNotEmpty() || heading.anchorFallback.isNotEmpty()), heading.anchor, heading.anchorFallback,
            heading.title, heading.headingStyle?.anchorReveal)) }
        row.block?.let { includeContent(row.key, listOf(it to row.key)) }
    }
    entry.references.forEachIndexed { index, reference ->
        reference.blocks?.let { blocks ->
            val contentKey = "reference-${reference.number}"
            val rowKey = entry.readingRows.singleOrNull { it.referenceIndex == index }?.key ?: contentKey
            includeContent(rowKey, blocks.mapIndexed { blockIndex, block -> block to "$contentKey/block-$blockIndex" }, index)
        }
    }
    val fragment = target.substring(1)
    fun matches(value: String) = headings.mapNotNull { candidate ->
        val selected = when {
            candidate.anchor.isNotEmpty() && candidate.anchor == value -> HeadingAnchorSelection(
                candidate.anchor, HeadingAnchorKind.Primary, candidate.reveal?.primaryTop)
            candidate.fallback.isNotEmpty() && candidate.fallback == value -> HeadingAnchorSelection(
                candidate.fallback, HeadingAnchorKind.Fallback, candidate.reveal?.fallbackTop)
            else -> null
        }
        selected?.let { candidate.destination.copy(anchorMatch = it) }
    }
    // An unsupported source identity blocks namespace fallback even when another
    // owner has the same anchor. This is a refusal witness, never a selected path.
    fun select(values: List<HeadingDestination>) =
        values.firstOrNull { it.nativeNavigationUnavailable } ?: values.singleOrNull()
    val exact = matches(fragment)
    if (exact.isNotEmpty()) return select(exact)
    val spaced = matches(fragment.replace(' ', '_'))
    if (spaced.isNotEmpty()) return select(spaced)
    return headings.filter { it.label == fragment.replace('_', ' ') }.singleOrNull()
        ?.takeIf { it.anchor.isEmpty() && it.fallback.isEmpty() }?.destination
}
/** Compatibility for callers interested only in the owning lazy row. */
internal fun headingScrollKey(entry: Entry, target: String): String? = headingDestination(entry, target)?.rowKey

/** Missing published content is different from folded or intentionally blank authored rows. */
internal fun entryHasNoContent(entry: Entry): Boolean =
    entry.kind != "alias" && entry.redirect == null && entry.sections.isEmpty() &&
        entry.preamble.isEmpty() && entry.references.isEmpty() && entry.media.isEmpty()

/** Match only actual compiled reference identities; no source or fragment interpretation. */
/** Items before the section rows: title/actions, visible explanations and preamble. */
internal fun entryReadingStartIndex(entry: Entry, folded: Set<String>): Int =
    1 + (if ("abbreviations" in folded) 0 else entry.textDetails.size) +
        if (entry.preamble.isEmpty()) 0 else 1

/** An empty leaf duplicating the generated references group has no separate body. */
internal fun metadataReferenceHeadingKey(entry: Entry): String? {
    if (entry.referenceBatches != null || entry.references.isEmpty()) return null
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

internal fun referenceTargetIndex(entry: Entry, target: String): Int? {
    fun matches(index: Int) = entry.references[index].let { it.kind == ReferenceKind.Note && target == "#reference-${it.number}" }
    return if (entry.referenceBatches == null) entry.references.indices.firstOrNull(::matches)
        else entry.references.indices.singleOrNull(::matches)
}

internal fun referenceScrollIndex(entry: Entry, target: String, folded: Set<String>): Int? =
    referenceTargetIndex(entry, target)?.let { referenceItemScrollIndex(entry, it, folded) }

internal fun referenceFoldKeys(entry: Entry, referenceIndex: Int): Set<String> {
    if (entry.referenceBatches == null) return setOf("references")
    val row = entry.readingRows.singleOrNull { it.referenceIndex == referenceIndex || it.referenceBatch?.referenceIndices?.contains(referenceIndex) == true } ?: return emptySet()
    return buildSet { add(row.sectionKey); if (row.meaningSection) add(row.sectionKey + "-details") }
}

internal fun referenceItemScrollIndex(entry: Entry, referenceIndex: Int, folded: Set<String>): Int? {
    if (referenceIndex !in entry.references.indices) return null
    if (entry.referenceBatches == null) return metadataReferencesStartIndex(entry, folded) + 1 + referenceIndex
    val rows = visibleEntryReadingRows(entry, folded)
    val index = rows.indexOfFirst { it.referenceIndex == referenceIndex || it.referenceBatch?.referenceIndices?.contains(referenceIndex) == true }
    return index.takeIf { it >= 0 }?.let {
        val start = if (rows[it].referenceBatch != null) floatBodyRuns(rows, entry.bodyAdjoining, entry.language)
            .firstOrNull { range -> it in range }?.first ?: it else it
        entryReadingStartIndex(entry, folded) + start
    }
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
