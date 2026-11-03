package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class GrammarFixtureTest {
    private fun fixture(): Entry = BlobDecoder.decode(
        javaClass.getResourceAsStream("/grammar-fixture-v2.dpr2")!!.use { it.readBytes() },
        "Grammar fixture_猫", "language", "English", "en"
    )

    @Test fun actualCompilerListsTablesAndTermsKeepTheirHierarchyWithoutAddingSenses() {
        val entry = fixture()
        val blocks = entry.sections.flatMap { it.blocks }
        val ordered = blocks.filter { it.kind == "list_item" && it.number.isNotEmpty() }
        assertEquals(listOf("3", "1", "8", "9", "ii", "i"), ordered.map { it.number })
        assertEquals(listOf("3. ", "1. ", "8. ", "9. ", "ii. ", "i. "), ordered.map(::blockPrefix))
        val nestedOrdered = ordered.single { it.listPath == "#*#" }
        assertEquals(3, nestedOrdered.depth)
        assertEquals(14, blockIndentDp(nestedOrdered))
        val nestedBullet = blocks.single { it.kind == "list_item" && it.listPath == "#*" }
        assertEquals("• ", blockPrefix(nestedBullet))
        assertEquals(7, blockIndentDp(nestedBullet))

        val tables = blocks.filter { it.table != null }
        assertEquals(2, tables.size)
        val nestedTable = tables.single { it.listPath == "#:" }
        assertEquals("table", nestedTable.kind)
        assertEquals(2, nestedTable.depth)
        assertEquals(7, blockIndentDp(nestedTable))
        assertEquals(listOf("nested left", "nested right"), nestedTable.table!!.rows.single().map { cell -> cell.spans.joinToString("") { it.text } })
        val ordinaryTable = tables.single { it.listPath.isEmpty() }
        assertEquals(0, blockIndentDp(ordinaryTable))
        assertEquals("Actual caption", ordinaryTable.table!!.caption.joinToString("") { it.text })
        assertEquals(2, ordinaryTable.table.rows.size)
        for ((kind, path) in listOf("term" to "*;", "list_detail" to "*:")) {
            val nested = blocks.single { it.kind == kind && it.listPath == path }
            assertEquals(2, nested.depth)
            assertEquals(7, blockIndentDp(nested))
        }
        assertEquals(1, blocks.count { it.kind == "definition" })
        assertEquals("A real dictionary meaning with a link and an & entity.", entry.clue())
        val displayedTables = entry.readingRows.mapNotNull { it.block }.filter { it.table != null }
        assertEquals(listOf(2, 0), displayedTables.map { it.depth })
        assertEquals(listOf("#:", ""), displayedTables.map { it.listPath })
    }

    @Test fun actualCompilerProtectedTextAndReferenceTargetsStayLiteralAndLocal() {
        val entry = fixture()
        val spans = entry.sections.flatMap { it.blocks }.flatMap { it.spans }
        val text = spans.joinToString("") { it.text + it.trail }
        assertTrue(text.contains("{{Example}} [[Link]] __NOEDITSECTION__"))
        assertTrue(text.contains("{{EntityLiteral}}"))
        val link = spans.single { it.target == "#reference-1" }
        assertEquals("link", link.kind)
        assertEquals("[audit 1]", link.text)
        assertEquals("reference", link.role)
        val reference = entry.references.single()
        assertEquals("[audit 1]", referenceLabel(reference))
        assertEquals("{{ReferenceLiteral}} __NOEDITSECTION__", reference.spans.joinToString("") { it.text })
        assertNotNull(referenceScrollIndex(entry, link.target, setOf("references", "heading-1-details")))
        assertEquals("{{MediaLiteral}} __NOEDITSECTION__", entry.media.single().caption)
    }
}
