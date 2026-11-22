package app.smallthingz.dict

/** One direct flow/flex owner, with original block addresses retained inside logical lists. */
internal sealed interface ContainerFlowItem {
    data class Block(val index: Int, val listContinuation: Boolean = false) : ContainerFlowItem
    data class ListGroup(val path: String, val items: List<ListItem>) : ContainerFlowItem
    data class ListItem(val index: Int, val children: List<ContainerFlowItem>)
}

private sealed interface ContainerFlowDraft {
    data class Block(val index: Int, val continuation: Boolean = false) : ContainerFlowDraft
    class Group(val path: String, val items: MutableList<Item> = mutableListOf()) : ContainerFlowDraft
    class Item(val index: Int, val children: MutableList<ContainerFlowDraft> = mutableListOf())
}

/** Match the established appendBlocks UL/OL projection; term and indent do not invent a DL. */
internal fun containerFlowItems(blocks: List<Block>): List<ContainerFlowItem> {
    val roots = mutableListOf<ContainerFlowDraft>()
    val lists = mutableListOf<ContainerFlowDraft.Group>()
    val itemPath = Regex("^[*#:;]*[*#]$")
    val detailPath = Regex("^([*#:;]*[*#]):+$")
    blocks.forEachIndexed { index, block ->
        if (block.kind == "list_item") {
            val key = block.listPath.takeIf(itemPath::matches) ?: if (block.number.isNotEmpty()) "#" else "*"
            var at = lists.indexOfFirst { it.path == key }
            if (at < 0) {
                while (lists.isNotEmpty() && !key.startsWith(lists.last().path)) lists.removeAt(lists.lastIndex)
                val owner = lists.lastOrNull()?.items?.lastOrNull()?.children ?: roots
                val group = ContainerFlowDraft.Group(key)
                owner += group
                lists += group
                at = lists.lastIndex
            }
            while (lists.lastIndex > at) lists.removeAt(lists.lastIndex)
            lists[at].items += ContainerFlowDraft.Item(index)
        } else {
            val continuation = if (block.kind == "list_detail") detailPath.matchEntire(block.listPath)?.groupValues?.get(1) else null
            val at = if (continuation == null) -1 else lists.indexOfFirst { it.path == continuation }
            val owner = lists.getOrNull(at)?.items?.lastOrNull()
            if (owner != null) {
                while (lists.lastIndex > at) lists.removeAt(lists.lastIndex)
                owner.children += ContainerFlowDraft.Block(index, continuation = true)
            } else {
                lists.clear()
                roots += ContainerFlowDraft.Block(index)
            }
        }
    }
    fun freeze(nodes: List<ContainerFlowDraft>): List<ContainerFlowItem> = nodes.map { node -> when (node) {
        is ContainerFlowDraft.Block -> ContainerFlowItem.Block(node.index, node.continuation)
        is ContainerFlowDraft.Group -> ContainerFlowItem.ListGroup(node.path, node.items.map { ContainerFlowItem.ListItem(it.index, freeze(it.children)) })
    } }
    return freeze(roots)
}
