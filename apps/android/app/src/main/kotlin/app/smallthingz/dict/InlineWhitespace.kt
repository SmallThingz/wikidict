package app.smallthingz.dict

/** Ordinary visual spacing only. Stored spans, exports and literal blocks remain intact. */
internal fun ordinaryInlineDisplaySpans(block: Block): List<Span> {
    val source = block.spans
    if (source.hasAuthoredFontFamily()) return source
    if (block.kind !in setOf("paragraph", "definition") || block.table != null ||
        source.any { it.hasClassToken("wikidict-poem") }) return source
    var inAsciiSpace = false
    fun display(text: String): String = buildString {
        for (character in text) {
            if (character == ' ' || character == '\t') {
                if (!inAsciiSpace) append(' ')
                inAsciiSpace = true
            } else {
                append(character)
                inAsciiSpace = false
            }
        }
    }
    val result = ArrayList<Span>(source.size)
    for (span in source) {
        // Native admission reports this source-valid domain; keep its original owner for fallback.
        if (span.isUnsupportedAuthoredWhitespaceOwner()) { result.add(span); continue }
        if (span.code || span.kind == "line_break" || span.background != null) {
            // Authored paint, literal code and explicit break/trails retain their extent.
            inAsciiSpace = false
            result.add(span)
            continue
        }
        if (span.image != null) inAsciiSpace = false
        val text = display(span.text)
        val trail = display(span.trail)
        // An entirely collapsed whitespace-only span must not leave an invisible
        // direction-isolate/link annotation. Surviving spans retain every flag/target.
        if (span.image != null || span.linkPaint != null || span.hasAuthoredInlineMetrics() || text.isNotEmpty() || trail.isNotEmpty() || (span.text.isEmpty() && span.trail.isEmpty())) {
            result.add(if (text == span.text && trail == span.trail) span else span.copy(text = text, trail = trail))
        }
    }
    return if (result == source) source else result
}
