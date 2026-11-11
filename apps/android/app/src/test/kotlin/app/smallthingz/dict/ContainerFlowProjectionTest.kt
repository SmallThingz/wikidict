package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class ContainerFlowProjectionTest {
    private fun block(kind: String, path: String = "", number: String = "") =
        Block(kind, path.length, listOf(Span("text", "$kind:$path:$number")), listPath = path, number = number)

    @Test fun adjacentRootsDetailsAndNestedListsKeepOneDirectFlexOwnerAndEveryAddress() {
        val blocks = listOf(block("list_item", "*"), block("list_detail", "*:"),
            block("list_item", "*#", "1"), block("list_detail", "*#:"),
            block("list_item", "*#", "2"), block("list_item", "*"), block("list_detail", "*::"))
        val group = containerFlowItems(blocks).single() as ContainerFlowItem.ListGroup
        assertEquals("*", group.path)
        assertEquals(listOf(0, 5), group.items.map { it.index })
        assertEquals(ContainerFlowItem.Block(1, true), group.items[0].children[0])
        val nested = group.items[0].children[1] as ContainerFlowItem.ListGroup
        assertEquals("*#", nested.path)
        assertEquals(listOf(2, 4), nested.items.map { it.index })
        assertEquals(listOf(ContainerFlowItem.Block(3, true)), nested.items[0].children)
        assertEquals(listOf(ContainerFlowItem.Block(6, true)), group.items[1].children)
    }

    @Test fun incompatibleRootContainerAndOrdinaryBlocksCloseTheLogicalList() {
        val child = Block("container", 0, emptyList(), container = Container(listOf(block("paragraph"))))
        val items = containerFlowItems(listOf(block("list_item", "*"), block("list_item", "#", "3"),
            child, block("list_item", "#", "4"), block("paragraph"), block("list_item", "#", "5")))
        assertEquals(6, items.size)
        assertEquals(listOf("*", "#", "#", "#"), items.filterIsInstance<ContainerFlowItem.ListGroup>().map { it.path })
        assertEquals(ContainerFlowItem.Block(2), items[2])
        assertEquals(ContainerFlowItem.Block(4), items[4])
        assertEquals(listOf(0, 1, 3, 5), items.filterIsInstance<ContainerFlowItem.ListGroup>().map { it.items.single().index })
    }

    @Test fun emptyPathsUseExistingListFallbackButOrphanDetailsAndDlRolesStayDirect() {
        val items = containerFlowItems(listOf(block("list_item"), block("list_item"),
            block("list_detail"), block("term", ";"), block("indent", ":"),
            block("list_item", number = "9"), block("list_detail", "*:"), block("list_item", "#", "10")))
        assertEquals(7, items.size)
        assertEquals(listOf(0, 1), (items[0] as ContainerFlowItem.ListGroup).items.map { it.index })
        assertEquals(listOf(2, 3, 4, 6), items.filterIsInstance<ContainerFlowItem.Block>().map { it.index })
        assertTrue(items.filterIsInstance<ContainerFlowItem.Block>().none { it.listContinuation })
        assertEquals(listOf("*", "#", "#"), items.filterIsInstance<ContainerFlowItem.ListGroup>().map { it.path })
    }
}
