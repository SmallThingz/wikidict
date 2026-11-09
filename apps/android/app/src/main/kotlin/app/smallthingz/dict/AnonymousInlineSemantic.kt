package app.smallthingz.dict

/** Mirrors the existing styled-text emission using explicit model boundaries, never character guessing. */
internal fun anonymousInlineSemantic(spans: List<Span>, nativeText: String): List<AnonymousInlineTextPart> {
    var offset = 0
    val parts = mutableListOf<AnonymousInlineTextPart>()
    fun literal(text: String) {
        check(nativeText.regionMatches(offset, text, 0, text.length)) { "Anonymous inline source drift" }
        if (text.isNotEmpty()) parts += AnonymousInlineTextPart(offset, offset + text.length, text)
        offset += text.length
    }
    spans.forEach { span ->
        val isolate = when (span.direction) { "ltr" -> '\u2066'; "rtl" -> '\u2067'; "auto" -> '\u2068'; else -> null }
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
