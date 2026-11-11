package app.smallthingz.dict

internal fun List<Span>.nativeLogicalLength(): Int = sumOf { span ->
    (if (span.image != null || span.kind == "line_break") 1 else span.text.length) + span.trail.length +
        if (span.direction in listOf("rtl", "ltr", "auto")) 2 else 0
}

/** Caption/table internals own separate containers; only this block's body starts an exclusion. */
internal fun Block.hasBodyFloat(): Boolean {
    fun Figure.floats() = placement == FigurePlacement.FloatLeft || placement == FigurePlacement.FloatRight
    fun parts(values: List<FlowPart>): Boolean = values.any { part -> when (part) {
        is FlowPart.Inline -> false
        is FlowPart.ImageFigure -> part.figure.floats()
        is FlowPart.Scope -> parts(part.scope.parts)
    } }
    return table?.style?.floatSide != null || figure?.floats() == true ||
        flow?.let(::parts) == true
}

/** Keep stable lazy row slots while one context owns every visible row after the first float. */
internal fun floatBodyRuns(rows: List<ReadingRow>): List<IntRange> {
    val first = rows.indexOfFirst { it.block?.needsNativeBlockContext() == true }
    return if (first < 0) emptyList() else listOf(first until rows.size)
}

/** An authored Container needs the same block context even when its active style has no float. */
internal fun Block.needsNativeBlockContext(): Boolean = container != null || hasBodyFloat()
