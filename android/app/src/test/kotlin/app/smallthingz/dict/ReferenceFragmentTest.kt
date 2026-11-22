package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class ReferenceFragmentTest {
    private data class Item(val tag: Int, val id: Long, val ordinal: Long = 1,
        val name: String = "", val group: String = "notes", val text: String = "Body",
        val media: Boolean = false)

    // Literal wire fixture independent of the production decoder: DPR9 adds exactly
    // one item discriminator; a fragment has no ordinal or authored-name slot.
    private fun fixture(version: Int, items: List<Item>, media: Boolean = false): ByteArray {
        fun u32(n: Long) = ByteArray(4) { (n ushr (it * 8)).toByte() }
        fun string(text: String) = text.toByteArray(Charsets.UTF_8).let { u32(it.size.toLong()) + it }
        fun span(item: Item): ByteArray = byteArrayOf(if (item.media) 1 else 0, 0, 0) +
            listOf(item.text, if (item.media) "File:Tone.ogg" else "", "", "",
                if (item.media) "wikidict-media" else "", "").fold(byteArrayOf()) { b, text -> b + string(text) } +
            (if (version >= 3) string("") else byteArrayOf()) +
            (if (version >= 4) byteArrayOf(0) else byteArrayOf()) +
            (if (version >= 6) byteArrayOf(0) else byteArrayOf())
        val references = items.fold(byteArrayOf()) { b, item -> b +
            (if (version >= 9) byteArrayOf(item.tag.toByte()) else byteArrayOf()) + u32(item.id) +
            (if (item.tag == 0 || version < 9) u32(item.ordinal) + string(item.name) else byteArrayOf()) +
            string(item.group) + u32(1) + span(item) }
        val mediaBytes = if (media) u32(1) + string("Tone.ogg") + byteArrayOf(1) + string("Fragment audio") else u32(0)
        return "DPR$version".toByteArray() + u32(0) + u32(0) + u32(0) + u32(0) + u32(0) +
            u32(items.size.toLong()) + references + mediaBytes
    }
    private fun decode(bytes: ByteArray) = BlobDecoder.decode(bytes, "Reference items", "language", "English", "en")

    @Test fun dpr9PreservesFragmentOrderStableIdsGroupAndMediaWithoutInventingANote() {
        val entry = decode(fixture(9, listOf(
            Item(1, 2, group = "notes", text = "Fragment audio", media = true),
            Item(0, 1, name = "named", text = "First numbered note"),
            Item(0, 3, ordinal = 2, text = "Second numbered note")), media = true))
        assertEquals(listOf(2L, 1L, 3L), entry.references.map { it.number })
        assertEquals(listOf(ReferenceKind.Fragment, ReferenceKind.Note, ReferenceKind.Note), entry.references.map { it.kind })
        assertEquals(listOf(null, 1L, 2L), entry.references.map { it.groupNumber })
        assertEquals(listOf("notes", "notes", "notes"), entry.references.map { it.group })
        assertEquals(listOf("Fragment audio", "First numbered note", "Second numbered note"), entry.references.map { textOf(it.spans) })
        assertEquals(listOf(Media("Tone.ogg", "audio", "Fragment audio")), entry.media)
        assertEquals(entry.media, MediaOwners(entry.media).embedded(entry.references.first().spans))
        assertEquals(listOf(null, "[notes 1]", "[notes 2]"), entry.references.map(::referenceLabel))
    }

    @Test fun legacyDpr2Through8AndAllNote9KeepTheSameNumberedReferenceModel() {
        val expected = Reference(7, 2, "notes", listOf(Span("text", "Legacy body")))
        for (version in 2..9) {
            val entry = decode(fixture(version, listOf(Item(0, 7, 2, "named", text = "Legacy body"))))
            assertEquals("DPR$version", listOf(expected), entry.references)
            assertEquals("[notes 2]", referenceLabel(entry.references.single()))
            assertNotNull(referenceScrollIndex(entry, "#reference-7", emptySet()))
        }
    }

    @Test fun fullWireReferenceIdsAndOrdinalsSurviveLegacyAndDpr9WithoutBecomingRowCounts() {
        for (version in 2..9) {
            for (value in listOf(2_147_483_648L, 4_294_967_294L)) {
                val entry = decode(fixture(version, listOf(Item(0, value, value, text = "Wide note"))))
                val note = entry.references.single()
                assertEquals(value, note.number)
                assertEquals(value, requireNotNull(note.groupNumber))
                assertEquals("[notes $value]", referenceLabel(note))
                // One item stays one row; the logical ID is never an array bound or index.
                assertEquals(2, referenceScrollIndex(entry, "#reference-$value", emptySet()))
                assertNull(referenceScrollIndex(entry, "#reference-0$value", emptySet()))
                assertNull(referenceScrollIndex(entry, "#reference-${value - 1}", emptySet()))
                val mixed = decode(fixture(9, listOf(Item(1, value), Item(0, 7))))
                assertEquals(value, mixed.references.first().number)
                assertNull(mixed.references.first().groupNumber)
                assertNull(referenceLabel(mixed.references.first()))
                assertNull(referenceScrollIndex(mixed, "#reference-$value", emptySet()))
                assertEquals(3, referenceScrollIndex(mixed, "#reference-7", emptySet()))
            }
            for (invalid in listOf(0L, 4_294_967_295L)) {
                assertThrows(Exception::class.java) { decode(fixture(version, listOf(Item(0, invalid)))) }
                assertThrows(Exception::class.java) { decode(fixture(version, listOf(Item(0, 1, invalid)))) }
                assertThrows(Exception::class.java) { decode(fixture(9, listOf(Item(1, invalid)))) }
            }
        }
        assertThrows(IllegalArgumentException::class.java) { Reference(4_294_967_295L, 1, "", emptyList()) }
        assertThrows(IllegalArgumentException::class.java) { Reference(1, 4_294_967_295L, "", emptyList()) }
    }

    @Test fun dpr9RejectsUnknownKindsInvalidIdentitiesOrdinalsAndTruncatedItems() {
        for (item in listOf(Item(2, 1), Item(255, 1), Item(1, 0), Item(0, 0),
                Item(1, 0xffffffffL), Item(0, 1, 0), Item(0, 1, 0xffffffffL))) {
            assertThrows(Exception::class.java) { decode(fixture(9, listOf(item))) }
        }
        val valid = fixture(9, listOf(Item(1, 2), Item(0, 1)))
        for (length in valid.indices) assertThrows(Exception::class.java) { decode(valid.copyOf(length)) }
        assertThrows(IllegalArgumentException::class.java) {
            Reference(2, 1, "notes", emptyList(), ReferenceKind.Fragment)
        }
        assertThrows(IllegalArgumentException::class.java) { Reference(1, null, "", emptyList()) }
    }

    @Test fun noteNavigationCountsFragmentsAsFooterRowsButDoesNotGiveThemCitationTargets() {
        val references = listOf(
            Reference(2, null, "notes", listOf(Span("text", "Fragment")), ReferenceKind.Fragment),
            Reference(1, 1, "notes", listOf(Span("text", "First note"))),
            Reference(3, 2, "notes", listOf(Span("text", "Second note"))))
        val entry = Entry("word", emptyList(), "language", "English", "en", listOf(
            Section(3, "Noun", listOf(Block("definition", 1, listOf(Span("text", "Meaning")))))),
            references, preamble = listOf(Span("text", "Preamble")))
        assertEquals(6, referenceScrollIndex(entry, "#reference-1", emptySet()))
        assertEquals(7, referenceScrollIndex(entry, "#reference-3", emptySet()))
        val folded = setOf("heading-0", "references", "preamble")
        assertEquals(5, referenceScrollIndex(entry, "#reference-1", folded))
        assertEquals(6, referenceScrollIndex(entry, "#reference-3", folded))
        assertNull(referenceScrollIndex(entry, "#reference-2", folded))
        val authored = entry.copy(sections = listOf(Section(3, "Authored heading", emptyList(), anchor = "reference-2")))
        assertEquals("heading-0", headingDestination(authored, "#reference-2")!!.rowKey)
        assertTrue(headingDestination(authored, "#reference-2")!!.compiledId)
    }
}
