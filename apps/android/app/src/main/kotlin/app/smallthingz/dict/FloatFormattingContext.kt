package app.smallthingz.dict

internal fun List<Span>.nativeLogicalLength(): Int = if (hasRuby()) rubyGraphicalText(this).length else sumOf { span ->
    (if (span.image != null || span.kind == "line_break") 1 else span.text.length) + span.trail.length +
        if (span.usesInlineDirectionIsolate()) 2 else 0
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

/** Keep stable lazy slots; an explicit body owner starts before the first visible semantic row. */
internal fun floatBodyRuns(rows: List<ReadingRow>, bodyAdjoining: BodyAdjoiningPolicy? = null,
    language: String? = null): List<IntRange> {
    val prefix = rows.firstOrNull()?.takeIf { it.heading?.isAuthoredBodyPrefix() == true }
    val headingPrefixStart = if (prefix != null && rows.any { it.heading?.headingStyle != null })
        rows.indexOfFirst { it.sectionKey == prefix.key && it.block != null } else -1
    val first = when (bodyAdjoining) {
        null -> if (headingPrefixStart >= 0) headingPrefixStart else
            rows.indexOfFirst { it.heading?.headingStyle != null || it.block?.needsNativeBlockContext() == true }
        BodyAdjoiningPolicy.Ordinary -> rows.indexOfFirst { row ->
            row.block != null || row.heading?.let { sectionHeadingVisible(it, language) } == true
        }
    }
    return if (first < 0) emptyList() else listOf(first until rows.size)
}

/** An authored Container needs the same block context even when its active style has no float. */
internal fun Block.needsNativeBlockContext(): Boolean = ruleStyle != null || container != null || table?.blockViewport != null || hasBodyFloat() ||
    table?.style?.let { it.marginValues != null && !it.isInline } == true

/** An enrolled table cell needs its original native context even when its Figure
 * does not float. Only that exact source block receives the delegated owner. */
internal fun List<Block>.needsNativeBlockSequence(delegatedSource: Block?): Boolean =
    any { it.needsNativeBlockContext() } ||
        delegatedSource != null && size == 1 && single() === delegatedSource
