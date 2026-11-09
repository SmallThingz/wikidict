package app.smallthingz.dict

/** One anonymous owner, without synthesized paragraphs, list markers, spacers or reordered text. */
internal data class AnonymousFlowContext(
    val direction: BidiResolvedDirection,
    val language: String?,
    val textAlign: CellTextAlign?,
)
internal sealed interface AnonymousFlowEvent {
    data class OpenScope(val id: Int, val scope: BidiScope, val context: AnonymousFlowContext) : AnonymousFlowEvent
    data class CloseScope(val id: Int) : AnonymousFlowEvent
    data class Inline(val spans: List<Span>, val context: AnonymousFlowContext,
        val containingScopeId: Int? = null) : AnonymousFlowEvent {
        // The typed scope owns isolation in this stream. Keep effective direction in the DTO,
        // but do not ask legacy span rendering to create another owner for each descendant.
        val layoutSpans: List<Span> = if (containingScopeId == null) spans else spans.map { span ->
            if (span.direction.isEmpty()) span else span.copy(direction = "")
        }
    }
    data class FigureObject(val id: Int, val figure: Figure, val context: AnonymousFlowContext) : AnonymousFlowEvent {
        // Caption alignment inherits the semantic context, never physical placement or a first span.
        val captionContext: AnonymousFlowContext get() = context.copy(textAlign = figure.captionTextAlign ?: context.textAlign)
    }
}
internal data class AnonymousFlowContent(val owner: Block, val events: List<AnonymousFlowEvent>, val context: AnonymousFlowContext)

/**
 * Rendering must consume this entire event stream in one text layout. Closing a scope does not
 * flush a text fragment, and a FigureObject must occupy its real measured anchor in that stream.
 * This projection deliberately does not run the Unicode bidi algorithm or inspect visible text.
 */
internal fun anonymousFlowContent(block: Block, inherited: AnonymousFlowContext): AnonymousFlowContent {
    require(block.table == null && block.feature == null && block.acceptsAnonymousContent())
    val context = inherited.copy(textAlign = block.textAlign ?: inherited.textAlign)
    val events = mutableListOf<AnonymousFlowEvent>()
    var nextScope = 0
    var nextFigure = 0
    var remaining = 1 shl 20
    fun charge(count: Int) { require(count <= remaining); remaining -= count }
    fun emit(parts: List<FlowPart>, current: AnonymousFlowContext, depth: Int, containingScopeId: Int? = null) {
        require(depth <= MaxContentDepth)
        charge(parts.size)
        for (part in parts) when (part) {
            is FlowPart.Inline -> {
                charge(part.spans.size)
                events += AnonymousFlowEvent.Inline(part.spans, current, containingScopeId)
            }
            is FlowPart.ImageFigure -> {
                events += AnonymousFlowEvent.FigureObject(nextFigure++, part.figure, current)
            }
            is FlowPart.Scope -> {
                require(depth < MaxContentDepth)
                val scope = part.scope
                val child = current.copy(direction = scope.resolvedDirection,
                    language = scope.language ?: current.language)
                val id = nextScope++
                events += AnonymousFlowEvent.OpenScope(id, scope, child)
                emit(scope.parts, child, depth + 1, id)
                events += AnonymousFlowEvent.CloseScope(id)
            }
        }
    }
    when {
        block.flow != null -> emit(block.flow, context, 1)
        block.figure != null -> events += AnonymousFlowEvent.FigureObject(nextFigure++, block.figure, context)
        else -> events += AnonymousFlowEvent.Inline(block.spans, context)
    }
    return AnonymousFlowContent(block, events, context)
}
