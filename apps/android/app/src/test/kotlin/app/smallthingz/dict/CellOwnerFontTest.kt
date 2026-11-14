package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Literal P0x80 transport and owner inheritance; native font geometry remains a device control. */
class CellOwnerFontTest {
    private fun owner(size: Float = 1.1f, basis: FontScaleBasis = FontScaleBasis.NormalBody) =
        InlineFontSnapshot(size, basis, bold = true, language = "th",
            fontFeatures = FontFeaturePolicy.entries.first(), fontFamily = ContainerFontFamily.SansSerif)
    private fun strut(font: InlineFontSnapshot = owner()) =
        CellTextStrut(checkNotNull(font.fontScale), font.fontScaleBasis, font)
    private fun cell(font: InlineFontSnapshot? = owner(), header: Boolean = false) = Cell(
        listOf(Span("link", "child", "Target", trail = "!", bold = false, italic = true,
            fontScale = .25f, fontScaleBasis = FontScaleBasis.NormalBody)), header, 1, 1,
        style = CellStyle(lineHeight = CellLineHeight(CellLineHeightValue.Normal,
            CellTextStrut(1.1f, FontScaleBasis.NormalBody, font))))
    private fun rejects(body: () -> Any?) = assertTrue(runCatching(body).isFailure)

    @Test fun completeOwnerAdmitsZeroAndBothBasesWithoutChangingAnyChildActionOrFont() {
        for (basis in listOf(FontScaleBasis.NormalBody, FontScaleBasis.CssPx)) for (size in listOf(0f, 1.1f, 12.375f)) {
            val font = owner(size, basis)
            assertEquals(font, strut(font).ownerFont)
            assertEquals(size, strut(font).fontScale, 0f)
        }
        val original = cell(null)
        val owned = original.copy(style = CellStyle(lineHeight = CellLineHeight(CellLineHeightValue.Normal, strut())))
        assertSame(original.spans, owned.spans)
        assertEquals(original.spans.single().entryLink(), owned.spans.single().entryLink())
        assertEquals(.25f, owned.spans.single().fontScale!!, 0f)
        assertFalse(owned.spans.single().bold)
        assertTrue(owned.style!!.lineHeight!!.strut!!.ownerFont!!.bold)
    }

    @Test fun incompleteConflictingOrPaintOnlyOwnerTraitsAreRejected() {
        val font = owner()
        val invalid = listOf(font.copy(fontScale = 2f), font.copy(fontScaleBasis = FontScaleBasis.CssPx),
            font.copy(fontScale = null, fontScaleBasis = FontScaleBasis.Context), font.copy(fontFamily = null),
            font.copy(fontFeatures = null), font.copy(language = ""), font.copy(language = "x".repeat(1025)),
            font.copy(small = true), font.copy(superscript = true), font.copy(subscript = true),
            font.copy(fontNormalized = true), font.copy(code = true), font.copy(classes = "label"),
            font.copy(role = "label"))
        invalid.forEach { bad -> rejects { CellTextStrut(1.1f, FontScaleBasis.NormalBody, bad) } }
        rejects { owner().copy(language = "bad\u0000language") }
        rejects { owner().copy(language = "\uD800") }
        for (number in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY))
            rejects { CellTextStrut(number, FontScaleBasis.NormalBody, owner()) }
        assertNull(CellTextStrut(1.1f, FontScaleBasis.NormalBody).ownerFont)
    }

    private class Wire {
        val out = ByteArrayOutputStream()
        val marks = linkedMapOf<String, Int>()
        fun mark(name: String) { marks.putIfAbsent(name, out.size()) }
        fun byte(n: Int) { out.write(n) }
        fun short(n: Int) { byte(n); byte(n ushr 8) }
        fun int(n: Int) { repeat(4) { byte(n ushr (it * 8)) } }
        fun number(n: Float) = int(n.toRawBits())
        fun text(s: String) { val bytes = s.encodeToByteArray(); int(bytes.size); out.write(bytes) }
        fun length(n: Float) { byte(0); number(n) }
        fun edges() { repeat(4) { length(0f) } }
        fun span() {
            byte(1); byte(0); byte(2)
            text("child"); text("Target"); text("!"); text("en"); text(""); text(""); text("")
            byte(0); byte(0); byte(1); number(.25f); byte(1); byte(0); byte(1); text("Anchor"); byte(0)
        }
        fun header(kind: Int) { byte(kind); byte(0); byte(0); int(0); byte(0); text(""); text("") }
        fun tail() { text(""); text(""); repeat(4) { byte(0) } }
        fun snapshot(duplicateSize: Boolean = false, face: Int = 25, language: String = "th") {
            mark("fontFlags"); byte(if (duplicateSize) 1 else 0)
            if (duplicateSize) { number(1f); byte(0) }
            mark("face"); byte(face); text(language); text(""); byte(0)
            if (face and 8 != 0) { mark("features"); byte(0) }
            if (face and 16 != 0) { mark("family"); byte(0) }
        }
        fun table(marker: Int = 2, duplicateSize: Boolean = false, face: Int = 25,
            language: String = "th", child: (Wire.() -> Unit)? = null, nested: Boolean = false) {
            header(12); byte(1); byte(0); int(0); int(1); int(1)
            byte(1); short(1); short(1); byte(0)
            int(if (child == null) 1 else 0); if (child == null) span()
            if (nested && child != null) {
                // Nested Table payload is the same Table fields without its Block header/tail.
                val payload = Wire().apply(child).out.toByteArray()
                out.write(payload.copyOfRange(16, payload.size - 12)); byte(0)
            } else {
                byte(0); byte(if (child == null) 0 else 1)
                if (child != null) { int(1); child() }
            }
            byte(1); byte(8); mark("marker"); byte(marker)
            if (marker != 0) {
                mark("size"); number(1.1f); mark("basis"); byte(1)
                if (marker == 2) snapshot(duplicateSize, face, language)
            }
            mark("height"); byte(1); number(1.25f)
            byte(0); byte(0); tail()
        }
        fun container(child: Wire.() -> Unit) { header(13); byte(0); tail(); int(0); int(1); child() }
        fun figurePayload(child: Wire.() -> Unit) {
            byte(2); byte(0); byte(0); byte(0); repeat(3) { edges() }; number(1f); length(12f)
            byte(1); byte(0); byte(1); byte(0); byte(0); byte(1)
            // Missing content owns a complete label, without the table child's separate trail.
            byte(1); byte(0); byte(2)
            text("child"); text("Target"); text(""); text("en"); text(""); text(""); text("")
            byte(0); byte(0); byte(1); number(.25f); byte(1); byte(0); byte(1); text("Anchor"); byte(0)
            length(20f); length(10f); byte(0)
            int(0); byte(1); int(1); child(); byte(0); byte(0)
        }
        fun figure(child: Wire.() -> Unit) {
            header(0); byte(0); text(""); text(""); byte(0); byte(0)
            figurePayload(child); byte(0)
        }
        fun flowFigure(child: Wire.() -> Unit) {
            header(0); byte(0); text(""); text(""); byte(0); byte(0); byte(0)
            byte(1); int(1); byte(1); figurePayload(child)
        }
        fun document(features: Int = 0x84, version: Char = 'P', reference: Boolean = false,
            root: Wire.() -> Unit = { table() }): ByteArray {
            out.write("DPR$version".toByteArray()); int(0); int(if (reference) 0 else 1)
            if (!reference) { byte(2); text("Cell"); text(""); text(""); int(1); root() }
            int(0); int(0); int(0); int(if (reference) 1 else 0)
            if (reference) { byte(1); int(1); text("refs"); int(0); byte(1); int(1); root() }
            int(0); if (version == 'P') { mark("census"); byte(features) }
            return out.toByteArray()
        }
    }
    private fun decode(bytes: ByteArray) = BlobDecoder.decode(bytes, "cell", "language", "English", "en")
    private fun onlyCell(entry: Entry) = entry.sections.single().blocks.single().table!!.rows.single().single()
    private fun changed(bytes: ByteArray, at: Int, n: Int) = bytes.copyOf().also { it[at] = n.toByte() }

    @Test fun ownedMarkerRestoresOneSizeAndKeepsChildBodyActionAndHeight() {
        val actual = onlyCell(decode(Wire().document()))
        val line = actual.style!!.lineHeight!!
        assertEquals(owner(), line.strut!!.ownerFont)
        assertEquals(1.1f, line.strut.fontScale, 0f)
        assertEquals(CellLineHeightValue.Multiplier(1.25f), line.height)
        assertEquals("child", actual.spans.single().text)
        assertEquals("!", actual.spans.single().trail)
        assertEquals(EntryLink("Target", "Anchor"), actual.spans.single().entryLink())
        assertFalse(actual.spans.single().bold); assertTrue(actual.spans.single().italic)
        assertEquals(.25f, actual.spans.single().fontScale!!, 0f)
    }

    @Test fun censusTraversesContainersOrderedCellsNestedTablesFigureFlowAndReferences() {
        val direct = onlyCell(decode(Wire().document())).style!!.lineHeight!!.strut
        val container = decode(Wire().document { container { table() } })
        assertEquals(direct, container.sections.single().blocks.single().container!!.blocks.single()
            .table!!.rows.single().single().style!!.lineHeight!!.strut)
        val ordered = onlyCell(decode(Wire().document { table(marker = 1, child = { table() }) }))
        assertEquals(direct, ordered.blocks!!.single().table!!.rows.single().single().style!!.lineHeight!!.strut)
        val nested = onlyCell(decode(Wire().document { table(marker = 1, child = { table() }, nested = true) }))
        assertEquals(direct, nested.nestedTable!!.rows.single().single().style!!.lineHeight!!.strut)
        val reference = decode(Wire().document(reference = true))
        assertEquals(direct, reference.references.single().blocks!!.single().table!!.rows.single().single().style!!.lineHeight!!.strut)
        val figure = decode(Wire().document { figure { table() } }).sections.single().blocks.single().figure!!
        assertEquals(direct, figure.captionBlocks!!.single().table!!.rows.single().single().style!!.lineHeight!!.strut)
        val flow = decode(Wire().document { flowFigure { table() } }).sections.single().blocks.single().flow!!
        val flowFigure = (flow.single() as FlowPart.ImageFigure).figure
        assertEquals(direct, flowFigure.captionBlocks!!.single().table!!.rows.single().single().style!!.lineHeight!!.strut)
        val label = Span("link", "child", "Target", language = "en", italic = true,
            fontScale = .25f, fontScaleBasis = FontScaleBasis.NormalBody, targetFragment = "Anchor")
        val expectedMissing = FigureContent.Missing(label,
            StyleLength(StyleLengthUnit.Px, 20f), StyleLength(StyleLengthUnit.Px, 10f))
        for (actual in listOf(figure, flowFigure)) {
            assertEquals(expectedMissing, actual.content)
            assertEquals(listOf(label.copy(trail = "!")),
                actual.captionBlocks!!.single().table!!.rows.single().single().spans)
        }
    }

    @Test fun malformedRawMarkerAndSnapshotAndCapabilityAreRefusedWithoutNormalization() {
        val wire = Wire(); val good = wire.document()
        for (n in good.indices) rejects { decode(good.copyOf(n)) }
        rejects { decode(good + byteArrayOf(0)) }
        for (version in listOf('M', 'N', 'O')) rejects { decode(Wire().document(version = version)) }
        for (marker in listOf(3, 128, 255)) rejects { decode(changed(good, wire.marks.getValue("marker"), marker)) }
        for (census in listOf(0, 4, 128, 0x8c, 0xff)) rejects { decode(changed(good, wire.marks.getValue("census"), census)) }
        for (basis in listOf(0, 3, 255)) rejects { decode(changed(good, wire.marks.getValue("basis"), basis)) }
        for (flags in listOf(2, 4, 8, 16, 32, 128)) rejects { decode(changed(good, wire.marks.getValue("fontFlags"), flags)) }
        for (field in listOf("features", "family")) rejects { decode(changed(good, wire.marks.getValue(field), 255)) }
        rejects { decode(Wire().document { table(duplicateSize = true) }) }
        for (face in listOf(1, 9, 17, 29, 128)) rejects { decode(Wire().document { table(face = face) }) }
        for (language in listOf("", "x".repeat(1025), "bad\u0000language"))
            rejects { decode(Wire().document { table(language = language) }) }
    }

    @Test fun legacyNullMarkersKeepTheirOldModelAndCannotClaimOwnerCapability() {
        for (marker in listOf(0, 1)) {
            val m = onlyCell(decode(Wire().document(version = 'M', root = { table(marker = marker) })))
            for (version in listOf('N', 'O'))
                assertEquals(m, onlyCell(decode(Wire().document(version = version, root = { table(marker = marker) }))))
            assertEquals(m, onlyCell(decode(Wire().document(features = 1, root = { table(marker = marker) }))))
            rejects { decode(Wire().document(features = 0x84, root = { table(marker = marker) })) }
            assertNull(m.style!!.lineHeight!!.strut?.ownerFont)
        }
    }
}
