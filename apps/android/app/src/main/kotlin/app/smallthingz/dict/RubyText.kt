package app.smallthingz.dict

/** A logical source range, before native shaping or empty-clip visual excision. */
internal enum class RubyTextRole {
    Text, Owner, Segment, SegmentGap, Base, BaseGap, BaseText, Annotation, AnnotationGap, AnnotationText, PaddingGroup, ActionGroup, BoxGroup, OverlayContent, OverlayText, ClippedAbsolute, ClippedText,
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
    val overlayContent: InlineBoxOverlayContent? = null,
    val overlayIndex: Int? = null,
)

internal data class RubyTextProjection(val text: String, val ranges: List<RubyTextRange>)

/** Terminal coordinates differ from graphical Ruby coordinates. Keep the original
 * source alongside the one-way native input; clipping still owns its original children. */
internal data class RubyNativeTerminalProjection(val source: List<Span>, val spans: List<Span>,
    val projection: RubyTextProjection)

internal fun rubyNativeTerminalProjection(source: List<Span>, sourcePath: String = "ruby"): RubyNativeTerminalProjection {
    val spans = if (source.none { it.ruby != null || it.inlinePaddingGroup != null ||
        it.inlineActionGroup != null || it.inlineBoxGroup != null }) source else source.flatMap { span ->
        if (span.clippedAbsolute != null) listOf(span) else rubyFallbackSpans(listOf(span))
    }
    return RubyNativeTerminalProjection(source, spans, rubyGraphicalProjection(spans, sourcePath))
}

/** Base characters include retained gaps and trails, but never readings or rp. */
internal fun rubyBaseText(spans: List<Span>): String = buildString {
    fun appendBase(source: List<Span>) {
        source.forEach { span ->
            val ruby = span.ruby
            val padding = span.inlinePaddingGroup
            val action = span.inlineActionGroup
            val box = span.inlineBoxGroup
            val clipped = span.clippedAbsolute
            if (clipped != null) appendBase(clipped.children)
            else if (box != null) appendBase(inlineBoxSourceSpans(box))
            else if (action != null) appendBase(action.spans)
            else if (padding != null) appendBase(padding.spans)
            else if (ruby == null) append(span.text).append(span.trail) else ruby.segments.forEach { segment ->
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

/** Flattened semantic leaves inherit only their nearest stored group action. The
 * original occurrences remain in the projection and still own native layout/actions. */
internal fun rubyGraphicalSpans(spans: List<Span>): List<Span> {
    if (!spans.hasNativeInlineGroups()) return spans
    val ranges = rubyGraphicalProjection(spans).ranges
    return ranges.mapNotNull { range ->
        if (range.role == RubyTextRole.Owner || range.role == RubyTextRole.PaddingGroup ||
            range.role == RubyTextRole.ActionGroup || range.role == RubyTextRole.BoxGroup ||
            range.role == RubyTextRole.ClippedAbsolute || range.role == RubyTextRole.OverlayContent) null
        else range.span?.rubyFallbackAction(ranges.lastOrNull { ancestor ->
            (ancestor.role == RubyTextRole.PaddingGroup || ancestor.role == RubyTextRole.ActionGroup ||
                ancestor.role == RubyTextRole.BoxGroup || ancestor.role == RubyTextRole.ClippedAbsolute) &&
                range.path.startsWith(ancestor.path + "/") &&
                ancestor.span?.kind in setOf("link", "external_link")
        }?.span)
    }
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

    private fun appendSpans(spans: List<Span>, path: String, role: RubyTextRole, firstIndex: Int = 0) {
        spans.forEachIndexed { ordinal, span ->
            val index = firstIndex + ordinal
            val childPath = "$path/$index"
            val start = text.length
            val ruby = span.ruby
            val padding = span.inlinePaddingGroup
            val action = span.inlineActionGroup
            val box = span.inlineBoxGroup
            val clipped = span.clippedAbsolute
            if (clipped != null) group(RubyTextRange(RubyTextRole.ClippedAbsolute, childPath, start, start, span = span)) {
                // The real source remains addressable; native layout separately excises its visual allocation.
                appendSpans(clipped.children, "$childPath/clippedAbsolute/children", RubyTextRole.ClippedText)
            } else if (box != null) group(RubyTextRange(RubyTextRole.BoxGroup, childPath, start, start, span = span)) {
                for (boundary in 0..box.spans.size) {
                    box.overlays.forEachIndexed { overlayIndex, overlay ->
                        overlay.content?.takeIf { it.beforeChild == boundary.toLong() }?.let { body ->
                            val bodyPath = "$childPath/inlineBoxGroup/overlays/$overlayIndex/content"
                            group(RubyTextRange(RubyTextRole.OverlayContent, bodyPath, text.length, text.length,
                                overlayContent = body, overlayIndex = overlayIndex)) {
                                appendSpans(body.spans, "$bodyPath/spans", RubyTextRole.OverlayText)
                            }
                        }
                    }
                    if (boundary < box.spans.size)
                        appendSpans(listOf(box.spans[boundary]), "$childPath/inlineBoxGroup/spans", role, boundary)
                }
            } else if (action != null) group(RubyTextRange(RubyTextRole.ActionGroup, childPath, start, start, span = span)) {
                appendSpans(action.spans, "$childPath/inlineActionGroup/spans", role)
            } else if (padding != null) group(RubyTextRange(RubyTextRole.PaddingGroup, childPath, start, start, span = span)) {
                appendSpans(padding.spans, "$childPath/inlinePaddingGroup/spans", role)
            } else if (ruby == null) {
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

/** This transient semantic projection never changes the stored action census. */
private fun Span.rubyFallbackAction(owner: Span?): Span {
    if (owner == null) return this
    require(kind == "text" && target.isEmpty())
    val policy = owner.linkPaint
    val ownerForeground = owner.foreground ?: policy?.normal?.foreground
    require(policy == null || foreground == null || foreground == ownerForeground)
    if (text.isEmpty() && trail.isEmpty()) return this
    val underline = this.underline || owner.underline
    val projected = copy(kind = owner.kind, target = owner.target, targetFragment = owner.targetFragment,
        text = if (text.isEmpty()) trail else text, trail = if (text.isEmpty()) "" else trail,
        tooltip = tooltip ?: owner.tooltip, explanation = explanation.ifEmpty { owner.explanation },
        foreground = if (policy == null) foreground ?: owner.foreground else ownerForeground, linkPaint = policy,
        underline = policy?.normal?.underline ?: underline)
    return projected.rubyFallbackDecoration(underline, false)
}

/** Terminal projection retains all readings, including graphically auto-hidden ones.
 * Inherited base decoration is transient; reading/RP boundaries reset it. */
internal fun rubyFallbackSpans(spans: List<Span>): List<Span> = rubyFallbackProjection(spans, visual = false)

/** Visual fallback alone is not a logical selection/copy source. A mapped fallback owner
 * must retain the original projection when these fully clipped intervals are omitted. */
internal fun rubyVisualFallbackSpans(spans: List<Span>): List<Span> = rubyFallbackProjection(spans, visual = true)

private fun rubyFallbackProjection(spans: List<Span>, visual: Boolean): List<Span> = buildList {
    fun appendFallback(source: List<Span>, inheritedUnderline: Boolean = false, inheritedStrike: Boolean = false,
        inheritedAction: Span? = null) {
        source.forEach { span ->
            val ruby = span.ruby
            val padding = span.inlinePaddingGroup
            val action = span.inlineActionGroup
            val box = span.inlineBoxGroup
            val clipped = span.clippedAbsolute
            if (clipped != null) {
                if (!visual) appendFallback(clipped.children, inheritedUnderline || span.underline,
                    inheritedStrike || span.strike,
                    span.takeIf { it.kind == "link" || it.kind == "external_link" } ?: inheritedAction)
            } else if (box != null) appendFallback(inlineBoxSourceSpans(box), inheritedUnderline || span.underline, inheritedStrike || span.strike,
                span.takeIf { it.kind == "link" || it.kind == "external_link" } ?: inheritedAction)
            else if (action != null) appendFallback(action.spans, inheritedUnderline || span.underline, inheritedStrike || span.strike, span)
            else if (padding != null) appendFallback(padding.spans, inheritedUnderline || span.underline, inheritedStrike || span.strike,
                span.takeIf { it.kind == "link" || it.kind == "external_link" } ?: inheritedAction)
            else if (ruby == null) add(span.rubyFallbackAction(inheritedAction)
                .rubyFallbackDecoration(inheritedUnderline, inheritedStrike)) else ruby.segments.forEach { segment ->
                val underline = inheritedUnderline || span.underline
                val strike = inheritedStrike || span.strike
                appendFallback(segment.gapBefore, underline, strike, inheritedAction)
                segment.bases.forEach { base ->
                    appendFallback(base.gapBefore, underline, strike, inheritedAction)
                    appendFallback(base.spans, underline, strike, inheritedAction)
                }
                segment.annotations.forEach { annotation ->
                    appendFallback(annotation.gapBefore, inheritedAction = inheritedAction)
                    if (annotation.explicitFallback) {
                        appendFallback(annotation.fallbackBefore, inheritedAction = inheritedAction)
                        appendFallback(annotation.spans, inheritedAction = inheritedAction)
                        appendFallback(annotation.fallbackAfter, inheritedAction = inheritedAction)
                    } else {
                        val firstReading = size
                        appendFallback(annotation.spans, inheritedAction = inheritedAction)
                        val nonempty = subList(firstReading, size).any { it.text.isNotEmpty() || it.trail.isNotEmpty() }
                        if (nonempty) {
                            // Generated punctuation has no stored action owner.
                            add(firstReading, Span("text", "\uff08"))
                            add(Span("text", "\uff09"))
                        }
                    }
                }
            }
        }
    }
    appendFallback(spans)
}

internal fun rubyFallbackText(spans: List<Span>): String =
    rubyFallbackSpans(spans).joinToString("") { it.text + it.trail }

/** Logical traversal only. The normal-flow builder must continue to use box.spans. */
internal fun inlineBoxSourceSpans(box: InlineBoxGroup): List<Span> = buildList {
    for (boundary in 0..box.spans.size) {
        box.overlays.forEach { overlay ->
            overlay.content?.takeIf { it.beforeChild == boundary.toLong() }?.let { addAll(it.spans) }
        }
        if (boundary < box.spans.size) add(box.spans[boundary])
    }
}
