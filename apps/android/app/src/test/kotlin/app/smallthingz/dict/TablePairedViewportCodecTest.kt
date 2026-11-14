package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Independent literal DPRP framing; these controls have not been executed. */
class TablePairedViewportCodecTest {
    private enum class Owner { Direct, NestedCell, OrderedCell, RichCaption, Container, Reference }
    private class Wire {
        val out = ByteArrayOutputStream()
        val marks = linkedMapOf<String, Int>()
        fun mark(name: String) { check(marks.put(name, out.size()) == null) }
        fun byte(value: Int) { out.write(value) }
        fun u16(value: Int) { repeat(2) { byte(value ushr (8 * it)) } }
        fun u32(value: Long) { repeat(4) { byte((value ushr (8 * it)).toInt()) } }
        fun f32(value: Float) = u32(value.toRawBits().toLong())
        fun string(value: String) { val bytes = value.encodeToByteArray(); u32(bytes.size.toLong()); out.write(bytes) }
        fun length(value: Float = 0f) { byte(0); f32(value) }
        fun edges() { length(.25f); length(6.5f); length(5.25f); length(4.5f) }
        fun span(label: String, wrap: Boolean = false) {
            byte(1); byte(0); byte(0) // link, normal role, no static emphasis
            string(label); string("Target-$label"); string("s")
            string(""); string(""); string(""); string("")
            byte(1); string("#123456"); byte(0)
            byte(if (wrap) 8 else 0)
            if (wrap) { byte(32); byte(0) } // API07 InlineTextStyle.wrap Normal
            byte(0) // no image
            byte(1); string("part-$label"); byte(1); string("advice-$label")
        }
        fun blockHeader(kind: Int) { byte(kind); byte(0); byte(0); u32(0); byte(0); string(""); string("") }
        fun blockTail() { string(""); string(""); repeat(4) { byte(0) } }
        fun floatStyle() {
            byte(1); byte(28); byte(0) // collapse + fixed margins + right float
            byte(1); edges(); byte(1)
        }
        fun blockPolicy(name: String, paired: Boolean, mode: Int, color: Int?) {
            mark(name + "Narrow"); u32(639)
            if (paired) { byte(1); byte(8); byte(0); edges() }
            else {
                byte(1); byte(32); byte(24); byte(2); f32(70f)
                byte(1); length(); byte(0); byte(1); length(); byte(0); byte(0)
            }
            mark(name + "BoxSizing"); byte(1) // border-box
            mark(name + "MaxWidthUnit"); byte(2); mark(name + "MaxWidthValue"); f32(100f)
            byte(1); byte(4); byte(0); byte(1) // anonymous grid collapse
            mark(name + "NarrowGrid"); byte(0); mark(name + "NarrowLanguage"); string("de")
            if (paired) {
                mark(name + "Focus"); byte(mode)
                mark(name + "ColorPresence"); byte(if (color == null) 0 else 1)
                if (color != null) {
                    mark(name + "Color"); byte(color)
                    if (color == 2) { mark(name + "Rgb"); string("#3366cc") }
                }
                mark(name + "FocusEnd")
            }
        }
        fun floatPolicy(name: String, clear: Boolean) {
            mark(name + "Float"); u32(639)
            mark(name + "Containing"); byte(1) // containing RTL, grid LTR
            mark(name + "FloatGrid"); byte(0); mark(name + "FloatLanguage"); string("de")
            if (clear) byte(2) // Right
            mark(name + "FloatEnd")
        }
        fun tableBlock(name: String, tag: Int = 7, owner: Owner = Owner.Direct,
            wrap: Boolean = false, mode: Int = 1, color: Int? = 2) {
            blockHeader(12); table(name, tag, owner, wrap, mode, color); blockTail()
        }
        fun table(name: String, tag: Int, owner: Owner, wrap: Boolean, mode: Int, color: Int?) {
            val outer = owner == Owner.NestedCell || owner == Owner.OrderedCell || owner == Owner.RichCaption
            val actualTag = if (outer) 1 else tag
            mark(name + "Table"); byte(actualTag)
            mark(name + "Geometry"); byte(0); u32(0) // no legacy geometry or flat caption
            u32(if (outer) 1 else 2)
            repeat(if (outer) 1 else 2) { row ->
                val count = if (outer || row == 1) 1 else 2
                u32(count.toLong())
                repeat(count) { column ->
                    byte(if (!outer && row == 0 && column == 1) 1 else 0)
                    u16(if (!outer && row == 0 && column == 1) 7 else if (!outer && row == 1) 2 else 1)
                    u16(if (!outer && row == 0 && column == 0) 2 else 1); byte(0)
                    val child = outer && owner != Owner.RichCaption
                    u32(if (child) 0 else 1)
                    if (!child) span(if (row == 0 && column == 0) "A" else if (row == 0) "B" else "C", wrap && row == 0 && column == 0)
                    if (owner == Owner.NestedCell) table("leaf", tag, Owner.Direct, wrap, mode, color) else byte(0)
                    if (owner == Owner.OrderedCell) { byte(1); u32(1); tableBlock("leaf", tag, wrap = wrap, mode = mode, color = color) }
                    else byte(0)
                    byte(0) // cell style absent
                }
            }
            if (outer || actualTag == 3) byte(0) else floatStyle()
            if (owner == Owner.RichCaption) { byte(1); u32(1); tableBlock("leaf", tag, wrap = wrap, mode = mode, color = color) }
            else byte(0)
            mark(name + "BaseEnd")
            if (!outer && actualTag in listOf(3, 7)) blockPolicy(name, actualTag == 7, mode, color)
            if (!outer && actualTag in listOf(5, 7, 13)) floatPolicy(name, actualTag == 13)
            mark(name + "End")
        }
        fun document(owner: Owner = Owner.Direct, tag: Int = 7, version: Int = 80,
            features: Int = 32, wrap: Boolean = false, extraClear: Boolean = false,
            mode: Int = 1, color: Int? = 2): ByteArray {
            byte(68); byte(80); byte(82); byte(version); u32(0)
            u32(if (owner == Owner.Reference) 0 else 1)
            if (owner != Owner.Reference) {
                byte(0); string(""); string(""); string(""); u32(if (extraClear) 2 else 1)
                if (owner == Owner.Container) {
                    blockHeader(13); byte(0); blockTail(); u32(0); u32(1)
                    tableBlock("leaf", tag, wrap = wrap, mode = mode, color = color)
                } else tableBlock(if (owner == Owner.Direct) "leaf" else "outer", tag, owner, wrap, mode, color)
                if (extraClear) tableBlock("clear", 13)
            }
            u32(0); u32(0); u32(0) // preamble, lexemes, unowned sections
            u32(if (owner == Owner.Reference) 1 else 0)
            if (owner == Owner.Reference) {
                byte(1); u32(1); string(""); u32(0); byte(1); u32(1)
                tableBlock("leaf", tag, wrap = wrap, mode = mode, color = color)
            }
            u32(0) // media
            if (version == 80) { mark("Features"); byte(features) }
            return out.toByteArray()
        }
    }
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "Paired", "supplemental", null, "ja")
    private fun leaf(entry: Entry, owner: Owner = Owner.Direct): Table = when (owner) {
        Owner.Direct -> entry.sections.single().blocks.first().table!!
        Owner.NestedCell -> entry.sections.single().blocks.single().table!!.rows.single().single().nestedTable!!
        Owner.OrderedCell -> entry.sections.single().blocks.single().table!!.rows.single().single().blocks!!.single().table!!
        Owner.RichCaption -> entry.sections.single().blocks.single().table!!.captionBlocks!!.single().table!!
        Owner.Container -> entry.sections.single().blocks.single().container!!.blocks.single().table!!
        Owner.Reference -> entry.references.single().blocks!!.single().table!!
    }
    private fun rejects(bytes: ByteArray) {
        try { read(bytes); fail("Expected wire rejection") } catch (_: IllegalArgumentException) { }
        catch (_: IllegalStateException) { }
        catch (_: java.nio.BufferUnderflowException) { }
    }
    private fun changed(bytes: ByteArray, offset: Int, value: Int) = bytes.copyOf().also { it[offset] = value.toByte() }

    @Test fun literalPairTailHasRequiredFocusBetweenBlockAndFloatPayloads() {
        val oldWire = Wire(); val old = oldWire.document(tag = 5, version = 77)
        val wire = Wire(); val bytes = wire.document()
        val start = wire.marks.getValue("leafTable"); val base = wire.marks.getValue("leafBaseEnd")
        val focus = wire.marks.getValue("leafFocus"); val floating = wire.marks.getValue("leafFloat")
        assertEquals(7, bytes[start].toInt()); assertEquals(5, old[oldWire.marks.getValue("leafTable")].toInt())
        assertArrayEquals(old.copyOfRange(oldWire.marks.getValue("leafTable") + 1, oldWire.marks.getValue("leafBaseEnd")),
            bytes.copyOfRange(start + 1, base))
        assertArrayEquals(byteArrayOf(1, 1, 2, 7, 0, 0, 0, 35, 51, 51, 54, 54, 99, 99), bytes.copyOfRange(focus, floating))
        assertArrayEquals(old.copyOfRange(oldWire.marks.getValue("leafFloat"), oldWire.marks.getValue("leafFloatEnd")),
            bytes.copyOfRange(floating, wire.marks.getValue("leafFloatEnd")))
        val stripped = bytes.copyOfRange(0, base) + bytes.copyOfRange(floating, bytes.lastIndex)
        stripped[3] = 77; stripped[start] = 5
        assertArrayEquals(old, stripped)
        val table = leaf(read(bytes))
        assertEquals(TableScrollFocusPaint(TableScrollFocusMode.UaAuto, FigureColor.Rgb("#3366cc")), table.blockViewport!!.focusPaint)
        assertEquals(listOf(2, 1), table.rows.map { it.size }); assertEquals(3, tableGrid(table).cells.size)
        assertEquals(7, table.rows[0][1].colspan); assertEquals(2, table.rows[0][0].rowspan)
        val action = table.rows[0][0].spans.single()
        assertEquals("Target-A", action.target); assertEquals("part-A", action.targetFragment)
        assertEquals("s", action.trail); assertEquals("advice-A", action.tooltip)
        assertEquals(TableContainingDirection.Rtl, table.floatViewport!!.containingDirection)
        assertEquals(TableContainingDirection.Ltr, table.blockViewport!!.gridDirection)
    }

    @Test fun everyFocusVariantUsesStrictExistingFigureColorDomain() {
        for (color in listOf(null, 0, 1, 2)) {
            val table = leaf(read(Wire().document(color = color)))
            val expected = when (color) { 0 -> FigureColor.NativeTheme; 1 -> FigureColor.Transparent
                2 -> FigureColor.Rgb("#3366cc"); else -> null }
            assertEquals(TableScrollFocusPaint(TableScrollFocusMode.UaAuto, expected), table.blockViewport!!.focusPaint)
        }
        val wire = Wire(); val none = wire.document(mode = 0, color = null)
        assertArrayEquals(byteArrayOf(0, 0), none.copyOfRange(wire.marks.getValue("leafFocus"), wire.marks.getValue("leafFloat")))
        assertEquals(TableScrollFocusPaint(TableScrollFocusMode.AuthoredNone), leaf(read(none)).blockViewport!!.focusPaint)
        for (color in listOf(0, 1, 2)) rejects(Wire().document(mode = 0, color = color))
        rejects(Wire().document(mode = 2)); rejects(Wire().document(color = 3))
        val validWire = Wire(); val valid = validWire.document()
        rejects(changed(valid, validWire.marks.getValue("leafColorPresence"), 2))
        rejects(changed(valid, validWire.marks.getValue("leafRgb") + 5, 'G'.code))
        val focus = validWire.marks.getValue("leafFocus")
        rejects(valid.copyOfRange(0, focus) + valid.copyOfRange(focus + 1, valid.size))
        rejects(valid.copyOfRange(0, focus) + valid.copyOfRange(validWire.marks.getValue("leafFloat"), valid.size))
    }

    @Test fun pairedCapabilityIsRecursiveAndComposesWithApi07AndExistingClear() {
        for (owner in Owner.entries) {
            val wire = Wire(); val bytes = wire.document(owner = owner, wrap = true, features = 32 or 16 or 1)
            val entry = read(bytes); val table = leaf(entry, owner)
            assertEquals(BodyAdjoiningPolicy.Ordinary, entry.bodyAdjoining)
            assertEquals(TextWrap.Normal, table.rows[0][0].spans.single().inlineStyle!!.wrap)
            assertNotNull(table.blockViewport!!.focusPaint)
            for (flags in listOf(0, 1, 16, 32, 33, 49 or 64, 49 or 128))
                rejects(changed(bytes, wire.marks.getValue("Features"), flags))
        }
        val entry = read(Wire().document(extraClear = true, features = 32 or 8))
        assertNotNull(entry.sections.single().blocks[0].table!!.blockViewport)
        assertEquals(FigureClear.Right, entry.sections.single().blocks[1].table!!.floatViewport!!.narrowClear)
        rejects(Wire().document(extraClear = true, features = 32))
        rejects(Wire().document(features = 32 or 16))
        rejects(Wire().document(tag = 5, features = 32))
        rejects(Wire().document(tag = 1, features = 32))
    }

    @Test fun pairRejectsEarlierHeadersUnknownTagsTruncationAndMismatchedTail() {
        val wire = Wire(); val bytes = wire.document()
        for (version in listOf(77, 78, 79)) rejects(changed(bytes, 3, version))
        for (tag in listOf(2, 4, 6, 15, 255)) rejects(changed(bytes, wire.marks.getValue("leafTable"), tag))
        for (length in 0 until bytes.size) rejects(bytes.copyOf(length))
        val mutations = listOf(
            "leafNarrow" to 126, "leafNarrowGrid" to 1,
            "leafNarrowLanguage" to 0, "leafFloat" to 0,
            "leafFloatGrid" to 1, "leafContaining" to 2,
            "leafBoxSizing" to 2, "leafMaxWidthUnit" to 3)
        mutations.forEach { (mark, value) -> rejects(changed(bytes, wire.marks.getValue(mark), value)) }
        val mismatch = bytes.copyOf()
        mismatch[wire.marks.getValue("leafFloatLanguage") + 4] = 'f'.code.toByte()
        rejects(mismatch)
        val invalidWidth = bytes.copyOf(); val p = wire.marks.getValue("leafMaxWidthValue")
        repeat(4) { invalidWidth[p + it] = (Float.NaN.toRawBits() ushr (8 * it)).toByte() }
        rejects(invalidWidth)
    }

    @Test fun standaloneAndAbsentPairDocumentsKeepTheOldBytesAndSemantics() {
        for (tag in listOf(1, 3, 5)) {
            val old = Wire().document(tag = tag, version = 77)
            val current = Wire().document(tag = tag, features = 1)
            val reconstructed = current.copyOf(current.size - 1).also { it[3] = 77 }
            assertArrayEquals(old, reconstructed)
            val oldTable = leaf(read(old)); val newTable = leaf(read(current))
            assertEquals(oldTable, newTable); assertNull(newTable.blockViewport?.focusPaint)
            rejects(Wire().document(tag = tag, features = 32 or 1))
        }
    }
}
