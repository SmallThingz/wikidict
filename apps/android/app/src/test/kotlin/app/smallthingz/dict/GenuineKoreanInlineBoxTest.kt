package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Genuine ordinary C06 data boundary and original logical ranges, not native pixels or TalkBack. */
class GenuineKoreanInlineBoxTest {
    @Test fun genuineKoreanGeoyigsimjoC06KeepsActionlessBoxOneChildAndCompleteEntry() {
        // Exact normal Writer output, independently reviewed with the public Reader.
        // This is compiled semantic data, never source text or a JSON dictionary import.
        val bytes = checkNotNull(javaClass.getResourceAsStream("/zh-geoyigsimjo-c06.wikblb")).use { it.readBytes() }
        assertEquals(935, bytes.size)
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        assertEquals("d52e17c8ce2d72029d3eedd6f77ac0d09f665f4906bcd8a2405ecdb6d85f5291", digest)
        val entry = CountingInput(bytes.inputStream()).use { input ->
            assertEquals("WIKBLB08", input.bytes(8).decodeToString())
            val kind = blobKind(input.read())
            val code = input.nul(); val language = input.nul(); val title = input.nul()
            assertEquals("language", kind); assertEquals("ko", code)
            assertEquals("朝鮮語", language); assertEquals("거익심조", title)
            val length = input.varuint()
            assertEquals(898L, length)
            require(length <= bytes.size - input.position)
            val payload = input.bytes(length.toInt())
            assertEquals("DPRY", payload.copyOfRange(0, 4).decodeToString())
            BlobDecoder.decode(payload, title, kind, language, code).also {
                assertEquals(-1, input.read()); assertEquals(bytes.size.toLong(), input.position)
            }
        }
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edge = InlineBoxBorderEdge.Solid(StyleLength(StyleLengthUnit.Px, 1f), InlineBoxColor.Rgb("#cedff2"))
        val child = Span("link", "去益深造", target = "去益深造", language = "ko", tooltip = "对应汉字",
            background = "#f5faff", fontScale = 1.1f, fontScaleBasis = FontScaleBasis.NormalBody)
        val owner = Span("text", "", tooltip = "对应汉字", background = "#f5faff",
            fontScale = 1.1f, fontScaleBasis = FontScaleBasis.NormalBody,
            inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, zero, zero, zero),
                InlineBoxBorderEdges(edge, edge, edge, edge), spans = listOf(child)))
        val expectedSpans = listOf(Span("text", "汉字或谚汉混合表记："),
            Span("link", "거", target = "거"), Span("link", "익", target = "익"),
            Span("link", "심", target = "심"), Span("link", "조", target = "조"),
            Span("text", "〈"), owner, Span("text", "〉"), Span("text", " "), Span("text", " "))
        val expected = Entry("거익심조", emptyList(), "language", "朝鮮語", "ko", listOf(
            Section(2, "朝鮮語", emptyList(), anchor = "朝鮮語", anchorFallback = ".E6.9C.9D.E9.AE.AE.E8.AA.9E"),
            Section(3, "汉字词", listOf(Block("paragraph", 0, expectedSpans)),
                anchor = "汉字词", anchorFallback = ".E6.B1.89.E5.AD.97.E8.AF.8D")), emptyList(),
            organization = PresentationOrganization(emptyList(), listOf(0, 1)))
        assertEquals(expected, entry)
        val source = entry.sections[1].blocks.single().spans
        val actualOwner = source[6]
        val actualChild = checkNotNull(actualOwner.inlineBoxGroup).spans.single()
        assertFalse(actualOwner.hasInternalAction()); assertEquals("", actualOwner.target)
        assertTrue(actualChild.hasInternalAction()); assertEquals(EntryLink("去益深造"), actualChild.entryLink())
        val projection = rubyGraphicalProjection(source, "genuine/ko/body")
        val visible = "汉字或谚汉混合表记：거익심조〈去益深造〉  "
        assertEquals(visible, projection.text); assertEquals(22, projection.text.length)
        assertEquals(visible, rubyFallbackText(source))
        val box = projection.ranges.single { it.role == RubyTextRole.BoxGroup }
        val linked = projection.ranges.single { it.span === actualChild }
        assertSame(actualOwner, box.span); assertSame(actualChild, linked.span)
        assertEquals(15 to 19, box.start to box.end); assertEquals(15 to 19, linked.start to linked.end)
        assertEquals("genuine/ko/body/spans/6", box.path)
        assertEquals(box.path + "/inlineBoxGroup/spans/0", linked.path)
        // Equal intervals do not grant the actionless owner the child's action.
        val actions = projection.ranges.filter { it.span?.hasInternalAction() == true }
        assertEquals(listOf("거", "익", "심", "조", "去益深造"), actions.map { it.span!!.target })
        assertEquals(listOf(10 to 11, 11 to 12, 12 to 13, 13 to 14, 15 to 19), actions.map { it.start to it.end })
        for (flat in listOf(rubyGraphicalSpans(source), rubyFallbackSpans(source))) {
            assertEquals(visible, flat.joinToString("") { it.text + it.trail })
            assertEquals(listOf("거", "익", "심", "조", "去益深造"), flat.filter { it.hasInternalAction() }.map { it.target })
        }
        assertEquals(22f, spanFontPixels(actualOwner, 20f, 20f), 0f)
        assertEquals(22f, spanFontPixels(actualChild, 22f, 20f), 0f)
        val advisory = NativeTextAdvisoryIndex(projection)
        assertEquals("对应汉字", advisory.title(linked))
        assertEquals(listOf(linked), advisory.descendants(box))
        // Two stored advisory declarations are not two actions. Their native
        // virtual accessibility nodes and glyph/hit geometry require platform evidence.
        assertEquals(2, advisory.declarations.size)
        assertTrue(entry.rasterImages.isEmpty()); assertTrue(entry.references.isEmpty()); assertTrue(entry.media.isEmpty())
    }
}
