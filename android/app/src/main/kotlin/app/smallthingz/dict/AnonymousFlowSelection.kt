package app.smallthingz.dict

/** One semantic order; each figure keeps its independent physical caption layout. */
internal sealed interface AnonymousSelectionSegment {
    val start: Int
    val end: Int
    val nativeStart: Int
    val nativeEnd: Int
    data class Inline(val authored: AnonymousAuthoredRange, override val start: Int, override val end: Int) : AnonymousSelectionSegment {
        override val nativeStart: Int get() = authored.nativeStart
        override val nativeEnd: Int get() = authored.nativeEnd
    }
    data class Figure(val anchor: AnonymousFigureAnchor, override val start: Int, override val end: Int) : AnonymousSelectionSegment {
        override val nativeStart: Int get() = anchor.nativeOffset
        override val nativeEnd: Int get() = anchor.nativeOffset + 1
    }
}

internal class AnonymousFlowSelection private constructor(
    val text: String,
    val segments: List<AnonymousSelectionSegment>,
    private val nativeLength: Int,
) {
    fun at(offset: Int): AnonymousSelectionSegment? {
        require(offset in 0..text.length)
        // A boundary belongs to the following nonempty semantic owner, except at the final end.
        var low = 0
        var high = segments.size
        while (low < high) {
            val middle = (low + high) ushr 1
            if (segments[middle].end <= offset) low = middle + 1 else high = middle
        }
        return segments.getOrNull(low) ?: segments.lastOrNull { it.end == offset && it.end > it.start }
    }
    fun nativeOffset(offset: Int): Int {
        val segment = at(offset) ?: return 0
        return when (segment) {
            is AnonymousSelectionSegment.Inline -> segment.authored.nativeOffset(segment.authored.logicalStart + offset - segment.start)
            is AnonymousSelectionSegment.Figure -> if (offset == segment.end) segment.nativeEnd else segment.nativeStart
        }
    }
    fun semanticOffset(nativeOffset: Int): Int {
        require(nativeOffset in 0..nativeLength)
        var low = 0
        var high = segments.size
        while (low < high) {
            val middle = (low + high) ushr 1
            if (segments[middle].nativeStart <= nativeOffset) low = middle + 1 else high = middle
        }
        val segment = segments.getOrNull(low - 1) ?: return 0
        return when (segment) {
            is AnonymousSelectionSegment.Inline -> segment.start + segment.authored.logicalOffset(nativeOffset) - segment.authored.logicalStart
            is AnonymousSelectionSegment.Figure -> if (nativeOffset == segment.nativeStart) segment.start else segment.end
        }
    }
    companion object {
        fun build(offsets: AnonymousFlowOffsets, figureText: (AnonymousFigureAnchor) -> CharSequence): AnonymousFlowSelection {
            val text = StringBuilder()
            val segments = mutableListOf<AnonymousSelectionSegment>()
            val pieces = offsets.authored.map { it.nativeStart to it } + offsets.figures.map { it.nativeOffset to it }
            for ((_, piece) in pieces.sortedBy { it.first }) {
                val start = text.length
                when (piece) {
                    is AnonymousAuthoredRange -> {
                        text.append(offsets.logicalText, piece.logicalStart, piece.logicalEnd)
                        segments += AnonymousSelectionSegment.Inline(piece, start, text.length)
                    }
                    is AnonymousFigureAnchor -> {
                        text.append(figureText(piece))
                        segments += AnonymousSelectionSegment.Figure(piece, start, text.length)
                    }
                    else -> error("Unknown anonymous semantic owner")
                }
            }
            return AnonymousFlowSelection(text.toString(), segments, offsets.nativeText.length)
        }
    }
}
