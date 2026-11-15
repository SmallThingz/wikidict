package app.smallthingz.dict

/** A graphical source range, before the native shaper adds any layout-only bidi controls. */
internal enum class RubyTextRole {
    Text, Owner, Segment, SegmentGap, Base, BaseGap, BaseText, Annotation, AnnotationGap, AnnotationText,
}

internal data class RubyTextRange(
    val role: RubyTextRole,
    val path: String,
    val start: Int,
    val end: Int,
    val span: Span? = null,
    val segment: RubySegment? = null,
    val base: RubyBase? = null,
    val annotation: RubyAnnotation? = null,
)

internal data class RubyTextProjection(val text: String, val ranges: List<RubyTextRange>)

/** Base characters include retained gaps and trails, but never readings or rp. */
internal fun rubyBaseText(spans: List<Span>): String = buildString {
    fun appendBase(source: List<Span>) {
        source.forEach { span ->
            val ruby = span.ruby
            if (ruby == null) append(span.text).append(span.trail) else ruby.segments.forEach { segment ->
                appendBase(segment.gapBefore)
                segment.bases.forEach { base -> appendBase(base.gapBefore); appendBase(base.spans) }
            }
        }
    }
    appendBase(spans)
}

/** The first selected base's gap belongs outside this comparison; internal selected gaps do not. */
internal fun rubyAnnotationHidden(segment: RubySegment, annotation: RubyAnnotation): Boolean {
    val first = annotation.baseStart
    val count = annotation.baseCount
    require(first >= 0 && count > 0 && first <= segment.bases.size.toLong() &&
        count <= segment.bases.size.toLong() - first)
    val covered = buildString {
        for (index in first.toInt() until (first + count).toInt()) {
            val base = segment.bases[index]
            if (index != first.toInt()) append(rubyBaseText(base.gapBefore))
            append(rubyBaseText(base.spans))
        }
    }
    return rubyBaseText(annotation.spans) == covered
}

/** Group ranges exclude their own gap. Owner ranges include every visible descendant.
 * Records are in source pre-order, and even an empty original owner keeps its path and range. */
internal fun rubyGraphicalProjection(spans: List<Span>, sourcePath: String = "ruby"): RubyTextProjection =
    RubyGraphicalTextBuilder().build(spans, sourcePath)

internal fun rubyGraphicalText(spans: List<Span>): String = rubyGraphicalProjection(spans).text

/** Metadata consumers use visible original leaves; they must not replace the typed layout body. */
internal fun rubyGraphicalSpans(spans: List<Span>): List<Span> =
    if (spans.none { it.ruby != null }) spans else rubyGraphicalProjection(spans).ranges.mapNotNull {
        if (it.role == RubyTextRole.Owner) null else it.span
    }

private class RubyGraphicalTextBuilder {
    private val text = StringBuilder()
    private val ranges = mutableListOf<RubyTextRange>()

    fun build(spans: List<Span>, sourcePath: String): RubyTextProjection {
        appendSpans(spans, "$sourcePath/spans", RubyTextRole.Text)
        return RubyTextProjection(text.toString(), ranges.toList())
    }

    private fun group(range: RubyTextRange, append: () -> Unit) {
        val index = ranges.size
        ranges += range
        append()
        ranges[index] = range.copy(end = text.length)
    }

    private fun appendSpans(spans: List<Span>, path: String, role: RubyTextRole) {
        spans.forEachIndexed { index, span ->
            val childPath = "$path/$index"
            val start = text.length
            val ruby = span.ruby
            if (ruby == null) {
                when {
                    span.image != null -> text.append('\ufffc')
                    span.kind == "line_break" -> text.append('\n')
                    else -> text.append(span.text)
                }
                text.append(span.trail)
                ranges += RubyTextRange(role, childPath, start, text.length, span = span)
            } else group(RubyTextRange(RubyTextRole.Owner, childPath, start, start, span = span)) {
                appendRuby(ruby, "$childPath/ruby")
            }
        }
    }

    private fun appendRuby(ruby: Ruby, path: String) {
        ruby.segments.forEachIndexed { segmentIndex, segment ->
            val segmentPath = "$path/segments/$segmentIndex"
            appendSpans(segment.gapBefore, "$segmentPath/gapBefore", RubyTextRole.SegmentGap)
            group(RubyTextRange(RubyTextRole.Segment, segmentPath, text.length, text.length, segment = segment)) {
                segment.bases.forEachIndexed { baseIndex, base ->
                    val basePath = "$segmentPath/bases/$baseIndex"
                    appendSpans(base.gapBefore, "$basePath/gapBefore", RubyTextRole.BaseGap)
                    group(RubyTextRange(RubyTextRole.Base, basePath, text.length, text.length, base = base)) {
                        appendSpans(base.spans, "$basePath/spans", RubyTextRole.BaseText)
                    }
                }
                segment.annotations.forEachIndexed { annotationIndex, annotation ->
                    if (!rubyAnnotationHidden(segment, annotation)) {
                        val annotationPath = "$segmentPath/annotations/$annotationIndex"
                        appendSpans(annotation.gapBefore, "$annotationPath/gapBefore", RubyTextRole.AnnotationGap)
                        group(RubyTextRange(RubyTextRole.Annotation, annotationPath, text.length, text.length,
                            annotation = annotation)) {
                            appendSpans(annotation.spans, "$annotationPath/spans", RubyTextRole.AnnotationText)
                        }
                    }
                }
            }
        }
    }
}

/** Terminal-only decoration projection. Stored spans and state policies remain unchanged;
 * a copied link policy keeps its normal/static checksum while adding outer base underline. */
private fun Span.rubyFallbackDecoration(underline: Boolean, strike: Boolean): Span {
    val policy = linkPaint
    val painted = if (!underline || policy == null || listOf(policy.normal, policy.hover, policy.active,
        policy.hoverActive, policy.visited, policy.visitedHover, policy.visitedActive,
        policy.visitedHoverActive).all { it.underline }) policy else policy.copy(
        normal = policy.normal.copy(underline = true), hover = policy.hover.copy(underline = true),
        active = policy.active.copy(underline = true), hoverActive = policy.hoverActive.copy(underline = true),
        visited = policy.visited.copy(underline = true), visitedHover = policy.visitedHover.copy(underline = true),
        visitedActive = policy.visitedActive.copy(underline = true),
        visitedHoverActive = policy.visitedHoverActive.copy(underline = true))
    return if ((!underline || this.underline) && (!strike || this.strike) && painted === policy) this else
        copy(underline = this.underline || underline, strike = this.strike || strike, linkPaint = painted)
}

/** Terminal projection retains all readings, including graphically auto-hidden ones.
 * Inherited base decoration is transient; reading/RP boundaries reset it. */
internal fun rubyFallbackSpans(spans: List<Span>): List<Span> = buildList {
    fun appendFallback(source: List<Span>, inheritedUnderline: Boolean = false, inheritedStrike: Boolean = false) {
        source.forEach { span ->
            val ruby = span.ruby
            if (ruby == null) add(span.rubyFallbackDecoration(inheritedUnderline, inheritedStrike)) else ruby.segments.forEach { segment ->
                val underline = inheritedUnderline || span.underline
                val strike = inheritedStrike || span.strike
                appendFallback(segment.gapBefore, underline, strike)
                segment.bases.forEach { base ->
                    appendFallback(base.gapBefore, underline, strike)
                    appendFallback(base.spans, underline, strike)
                }
                segment.annotations.forEach { annotation ->
                    appendFallback(annotation.gapBefore)
                    if (annotation.explicitFallback) {
                        appendFallback(annotation.fallbackBefore)
                        appendFallback(annotation.spans)
                        appendFallback(annotation.fallbackAfter)
                    } else {
                        val reading = rubyFallbackSpans(annotation.spans)
                        val nonempty = reading.any { it.text.isNotEmpty() || it.trail.isNotEmpty() }
                        if (nonempty) add(Span("text", "\uff08"))
                        addAll(reading)
                        if (nonempty) add(Span("text", "\uff09"))
                    }
                }
            }
        }
    }
    appendFallback(spans)
}

internal fun rubyFallbackText(spans: List<Span>): String =
    rubyFallbackSpans(spans).joinToString("") { it.text + it.trail }
