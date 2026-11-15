package app.smallthingz.dict

/** Mirrors the existing styled-text emission using explicit model boundaries, never character guessing. */
internal fun anonymousInlineSemantic(spans: List<Span>, nativeText: String): List<AnonymousInlineTextPart> {
    if (spans.any { it.ruby != null }) {
        val projection = rubyGraphicalProjection(spans)
        check(nativeText == projection.text) { "Anonymous ruby source drift" }
        return buildList {
            projection.ranges.forEach { range ->
                val span = range.span ?: return@forEach
                if (range.role == RubyTextRole.Owner) return@forEach
                val image = span.image
                if (image != null) {
                    // An ordinary image sibling keeps its existing semantic alt policy.
                    // Ruby descendants cannot contain images; no Ruby owner becomes an object.
                    check(range.end == range.start + 1 + span.trail.length)
                    add(AnonymousInlineTextPart(range.start, range.start + 1,
                        image.alt.orEmpty(), replacement = true))
                    if (span.trail.isNotEmpty()) add(AnonymousInlineTextPart(range.start + 1,
                        range.end, span.trail))
                } else if (range.start < range.end) {
                    add(AnonymousInlineTextPart(range.start, range.end,
                        projection.text.substring(range.start, range.end)))
                }
            }
        }
    }
    var offset = 0
    val parts = mutableListOf<AnonymousInlineTextPart>()
    fun literal(text: String) {
        check(nativeText.regionMatches(offset, text, 0, text.length)) { "Anonymous inline source drift" }
        if (text.isNotEmpty()) parts += AnonymousInlineTextPart(offset, offset + text.length, text)
        offset += text.length
    }
    spans.forEach { span ->
        val isolate = if (!span.usesInlineDirectionIsolate()) null else when (span.direction) {
            "ltr" -> '\u2066'; "rtl" -> '\u2067'; "auto" -> '\u2068'; else -> null
        }
        isolate?.let { check(nativeText.getOrNull(offset++) == it) }
        val image = span.image
        if (image != null) {
            check(nativeText.getOrNull(offset) == '\ufffc')
            // Authored alt is semantic text; the internal object character is not copied or spoken.
            parts += AnonymousInlineTextPart(offset, offset + 1, image.alt.orEmpty(), replacement = true)
            offset++
        } else literal(if (span.kind == "line_break") "\n" else span.text)
        literal(span.trail)
        isolate?.let { check(nativeText.getOrNull(offset++) == '\u2069') }
    }
    check(offset == nativeText.length)
    return parts
}
