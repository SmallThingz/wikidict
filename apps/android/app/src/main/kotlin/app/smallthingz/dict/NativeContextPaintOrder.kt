package app.smallthingz.dict

/** Source IDs never change when the same owner's paint phase changes. */
internal data class NativePaintOrderNode(val source: Int, val positioned: Boolean = false,
    val children: List<NativePaintOrderNode> = emptyList())

internal fun nativeContextPaintSequence(roots: List<NativePaintOrderNode>): List<Int> {
    val ordinary = mutableListOf<Int>()
    val positioned = mutableListOf<NativePaintOrderNode>()
    val seen = mutableSetOf<Int>()
    fun visit(nodes: List<NativePaintOrderNode>) {
        nodes.forEach { node ->
            check(seen.add(node.source)) { "A paint owner must have one source identity" }
            if (node.positioned) positioned += node else {
                ordinary += node.source
                visit(node.children)
            }
        }
    }
    visit(roots)
    fun whole(node: NativePaintOrderNode) {
        ordinary += node.source
        node.children.forEach { child ->
            require(!child.positioned) { "Nested positioned groups need their own stacking policy" }
            check(seen.add(child.source))
            whole(child)
        }
    }
    // Relative-auto owners do not create stacking contexts. They join this Entry context's
    // positioned phase even when nested in an ordinary block; their body stays one paint group.
    positioned.forEach(::whole)
    return ordinary
}

internal data class NativePaintBox(val id: Int, val rank: Int, val leaves: Set<Int>)

/** The separate Figure caption renderer has no prepared Container/fragment owner yet. */
internal fun Block.hasColumnsOrPositionedContainer(): Boolean = when {
    container != null -> container.style.columns != null || container.style.positioning != null ||
        container.blocks.any(Block::hasColumnsOrPositionedContainer)
    table != null -> table.hasColumnsOrPositionedContainer()
    figure != null -> figure.captionBlocks?.any(Block::hasColumnsOrPositionedContainer) == true
    flow != null -> flow.hasColumnsOrPositionedContainer()
    else -> false
}

private fun Table.hasColumnsOrPositionedContainer(): Boolean =
    captionBlocks?.any(Block::hasColumnsOrPositionedContainer) == true || rows.any { row -> row.any { cell ->
        cell.blocks?.any(Block::hasColumnsOrPositionedContainer) == true ||
            cell.nestedTable?.hasColumnsOrPositionedContainer() == true
    } }

private fun List<FlowPart>.hasColumnsOrPositionedContainer(): Boolean = any { part -> when (part) {
    is FlowPart.Inline -> false
    is FlowPart.ImageFigure -> part.figure.captionBlocks?.any(Block::hasColumnsOrPositionedContainer) == true
    is FlowPart.Scope -> part.scope.parts.hasColumnsOrPositionedContainer()
} }

/** One input owner uses the same paint ranks as the real text and delegated child slots.
 * This projection never sorts the logical text, keyboard nodes or selection ranges. */
internal class NativeContextPaintInput(private val context: NativeFloatContextGeometry,
    leafRanks: Map<Int, Int>, childRanks: Map<Int, Int>, boxes: List<NativePaintBox>) : FloatTextGeometry by context {
    private data class TextTarget(val leaf: NativeContextInputLeaf, val rank: Int)
    private data class ChildTarget(val child: PlacedFloatContextChild, val rank: Int)
    private data class BoxTarget(val box: NativePaintBox, val bounds: android.graphics.RectF)
    private data class Winner(val rank: Int, val text: NativeContextInputLeaf? = null,
        val child: PlacedFloatContextChild? = null, val box: NativePaintBox? = null)
    private val textTargets = context.inputLeaves().map { TextTarget(it, leafRanks[it.sourceIndex]
        ?: throw UnsupportedFloatLayout("Text paint priority needs its original source owner")) }
    private val childTargets = context.children.map { ChildTarget(it, childRanks[it.id]
        ?: throw UnsupportedFloatLayout("Delegated paint priority needs its original source owner")) }
    private val boxTargets = boxes.mapNotNull { box -> context.ordinaryBounds[box.id]?.let { BoxTarget(box, it) } }

    private fun winner(x: Float, y: Float): Winner? {
        var best: Winner? = null
        fun accept(candidate: Winner) { if (best == null || candidate.rank > checkNotNull(best).rank) best = candidate }
        textTargets.forEach { target ->
            val leaf = target.leaf
            if (leaf.geometry.containsInteraction(x - leaf.x, y - leaf.y)) accept(Winner(target.rank, text = leaf))
        }
        childTargets.forEach { if (it.child.bounds.contains(x, y)) accept(Winner(it.rank, child = it.child)) }
        boxTargets.forEach { if (it.bounds.contains(x, y)) accept(Winner(it.box.rank, box = it.box)) }
        return best
    }

    override fun containsInput(x: Float, y: Float): Boolean = when (val hit = winner(x, y)) {
        null -> context.containsInput(x, y)
        else -> hit.child == null
    }

    override fun interactionNodeAt(x: Float, y: Float): FloatInteractionNode? {
        val leaf = winner(x, y)?.text ?: return null
        val local = leaf.geometry.interactionNodeAt(x - leaf.x, y - leaf.y) ?: return null
        val index = leaf.geometry.nodes.indexOfFirst { it.id == local.id }
        check(index >= 0)
        return nodes[leaf.nodeBase + index]
    }

    private fun nearestLeaf(indices: Set<Int>, x: Float, y: Float): NativeContextInputLeaf? =
        textTargets.asSequence().map { it.leaf }.filter { it.sourceIndex in indices }.minByOrNull { leaf ->
            val px = x - leaf.x
            val py = y - leaf.y
            leaf.geometry.rectsForRange(0, leaf.geometry.text.length).minOfOrNull { box ->
                val dx = maxOf(box.left - px, 0f, px - box.right).toDouble()
                val dy = maxOf(box.top - py, 0f, py - box.bottom).toDouble()
                dx * dx + dy * dy
            } ?: Double.POSITIVE_INFINITY
        }

    override fun offsetForPosition(x: Float, y: Float): Int {
        val hit = winner(x, y) ?: return context.offsetForPosition(x, y)
        hit.child?.let { return it.offset }
        val leaf = hit.text ?: hit.box?.let { nearestLeaf(it.leaves, x, y) }
            ?: return context.offsetForPosition(x, y)
        return leaf.offset + leaf.geometry.offsetForPosition(x - leaf.x, y - leaf.y)
    }
}
