package app.smallthingz.dict

/** Presentation-only rows. No source parsing: explicit semantic breaks are layout boundaries. */
data class ReadingRow(val key: String, val heading: Section? = null, val block: Block? = null, val compact: Boolean = false)

fun readingRows(sections: List<Section>): List<ReadingRow> = buildList {
    sections.forEachIndexed { sectionIndex, section ->
        add(ReadingRow("heading-$sectionIndex", heading = section))
        section.blocks.forEachIndexed { blockIndex, block ->
            val key = "block-$sectionIndex-$blockIndex"
            if (block.kind == "blank") return@forEachIndexed
            if (block.kind != "paragraph" || block.spans.size < 80 || block.spans.none { it.kind == "line_break" }) {
                add(ReadingRow(key, block = block))
            } else {
                var line = ArrayList<Span>()
                var part = 0
                for (span in block.spans) {
                    if (span.kind == "line_break") {
                        add(ReadingRow("$key-${part++}", block = block.copy(spans = line), compact = true))
                        line = ArrayList()
                        if (span.trail.isNotEmpty()) line.add(Span("text", span.trail))
                    } else line.add(span)
                }
                if (line.isNotEmpty()) add(ReadingRow("$key-$part", block = block.copy(spans = line), compact = true))
            }
        }
    }
}
