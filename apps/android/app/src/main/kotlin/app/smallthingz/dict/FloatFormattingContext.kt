package app.smallthingz.dict

internal fun List<Span>.nativeLogicalLength(): Int = sumOf { span ->
    (if (span.image != null || span.kind == "line_break") 1 else span.text.length) + span.trail.length +
        if (span.direction in listOf("rtl", "ltr", "auto")) 2 else 0
}

/** Keep stable lazy row slots while one context owns every visible row after the first table float. */
internal fun floatBodyRuns(rows: List<ReadingRow>): List<IntRange> {
    val first = rows.indexOfFirst { it.block?.table?.style?.floatSide != null }
    return if (first < 0) emptyList() else listOf(first until rows.size)
}
