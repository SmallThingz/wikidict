package app.smallthingz.dict

internal data class AnonymousAuthoredRange(
    val nativeStart: Int, val nativeEnd: Int, val logicalStart: Int, val logicalEnd: Int,
    val event: AnonymousFlowEvent.Inline,
    val replacement: Boolean = false,
) {
    fun nativeOffset(logical: Int): Int = if (replacement) {
        if (logical == logicalEnd) nativeEnd else nativeStart
    } else nativeStart + logical - logicalStart
    fun logicalOffset(native: Int): Int = if (replacement) {
        if (native >= nativeEnd) logicalEnd else logicalStart
    } else logicalStart + (native - nativeStart).coerceIn(0, logicalEnd - logicalStart)
}
internal data class AnonymousInlineSource(val start: Int, val end: Int, val event: AnonymousFlowEvent.Inline)
internal data class AnonymousInlineTextPart(val start: Int, val end: Int, val text: String,
    val replacement: Boolean = false)
internal data class AnonymousFigureAnchor(
    val nativeOffset: Int, val logicalOffset: Int, val event: AnonymousFlowEvent.FigureObject,
)

/** Generated bidi controls and figure anchors have no authored UTF-16 extent. */
internal class AnonymousFlowOffsets private constructor(
    val nativeText: String,
    val logicalText: String,
    val authored: List<AnonymousAuthoredRange>,
    val figures: List<AnonymousFigureAnchor>,
    val inlineSources: List<AnonymousInlineSource>,
) {
    fun logicalOffset(nativeOffset: Int): Int {
        require(nativeOffset in 0..nativeText.length)
        var low = 0
        var high = authored.size
        while (low < high) {
            val middle = (low + high) ushr 1
            if (authored[middle].nativeStart <= nativeOffset) low = middle + 1 else high = middle
        }
        val previous = authored.getOrNull(low - 1) ?: return 0
        return previous.logicalOffset(nativeOffset)
    }

    /** At a shared boundary the following authored run owns the caret, after generated controls. */
    fun nativeOffset(logicalOffset: Int): Int {
        require(logicalOffset in 0..logicalText.length)
        var low = 0
        var high = authored.size
        while (low < high) {
            val middle = (low + high) ushr 1
            if (authored[middle].logicalEnd <= logicalOffset) low = middle + 1 else high = middle
        }
        val following = authored.getOrNull(low)
        return if (following != null) following.nativeOffset(logicalOffset)
        else authored.lastOrNull()?.nativeEnd ?: 0
    }

    fun nativeRanges(start: Int, end: Int): List<IntRange> {
        require(start in 0..logicalText.length && end in start..logicalText.length)
        return authored.mapNotNull { range ->
            val first = maxOf(start, range.logicalStart)
            val last = minOf(end, range.logicalEnd)
            if (first >= last) null else if (range.replacement) range.nativeStart until range.nativeEnd
            else range.nativeOffset(first) until range.nativeOffset(last)
        }
    }

    companion object {
        /** Only explicit adapter ranges remove generated controls/anchors; authored controls stay literal. */
        fun build(content: AnonymousFlowContent,
            semantic: (AnonymousFlowEvent.Inline, String) -> List<AnonymousInlineTextPart> = { _, text ->
                listOf(AnonymousInlineTextPart(0, text.length, text))
            }, inlineText: (AnonymousFlowEvent.Inline) -> String): AnonymousFlowOffsets {
            val native = StringBuilder()
            val logical = StringBuilder()
            val authored = mutableListOf<AnonymousAuthoredRange>()
            val figures = mutableListOf<AnonymousFigureAnchor>()
            val sources = mutableListOf<AnonymousInlineSource>()
            val scopes = mutableListOf<AnonymousFlowEvent.OpenScope>()
            for (event in content.events) when (event) {
                is AnonymousFlowEvent.OpenScope -> {
                    check(scopes.none { it.id == event.id })
                    scopes += event
                    native.append(if (event.scope.resolvedDirection == BidiResolvedDirection.Ltr) '\u2066' else '\u2067')
                    if (event.scope.mode == BidiMode.IsolateOverride)
                        native.append(if (event.scope.resolvedDirection == BidiResolvedDirection.Ltr) '\u202d' else '\u202e')
                }
                is AnonymousFlowEvent.CloseScope -> {
                    val open = scopes.removeAt(scopes.lastIndex)
                    check(open.id == event.id)
                    if (open.scope.mode == BidiMode.IsolateOverride) native.append('\u202c')
                    native.append('\u2069')
                }
                is AnonymousFlowEvent.Inline -> {
                    val text = inlineText(event)
                    val nativeStart = native.length
                    native.append(text)
                    sources += AnonymousInlineSource(nativeStart, native.length, event)
                    var previousEnd = 0
                    semantic(event, text).forEach { part ->
                        require(part.start >= previousEnd && part.end in part.start..text.length)
                        require(part.replacement || text.substring(part.start, part.end) == part.text)
                        require(!part.replacement || part.end == part.start + 1 && text[part.start] == '\ufffc')
                        previousEnd = part.end
                        val logicalStart = logical.length
                        logical.append(part.text)
                        if (part.text.isNotEmpty()) authored += AnonymousAuthoredRange(nativeStart + part.start,
                            nativeStart + part.end, logicalStart, logical.length, event, part.replacement)
                    }
                }
                is AnonymousFlowEvent.FigureObject -> {
                    figures += AnonymousFigureAnchor(native.length, logical.length, event)
                    native.append('\ufffc')
                }
            }
            check(scopes.isEmpty())
            return AnonymousFlowOffsets(native.toString(), logical.toString(), authored, figures, sources)
        }
    }
}
