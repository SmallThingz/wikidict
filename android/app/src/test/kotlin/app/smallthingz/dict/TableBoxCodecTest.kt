package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Literal bytes keep new TableStyle framing independent of the producer implementation. */
class TableBoxCodecTest {
    private class Wire {
        val out = ByteArrayOutputStream()
        val marks = linkedMapOf<String, Int>()
        fun mark(name: String) { marks[name] = out.size() }
        fun byte(value: Int) { out.write(value) }
        fun u16(value: Int) { repeat(2) { byte(value ushr (8 * it)) } }
        fun u32(value: Int) { repeat(4) { byte(value ushr (8 * it)) } }
        fun f32(value: Float) = u32(value.toRawBits())
        fun string(value: String) { val raw = value.toByteArray(Charsets.UTF_8); u32(raw.size); out.write(raw) }
        fun length(value: Float, unit: Int = 0) { byte(unit); f32(value) }
        fun span(value: String, target: String = "") {
            byte(if (target.isEmpty()) 0 else 1); byte(0); byte(0)
            string(value); string(target); repeat(5) { string("") }; repeat(6) { byte(0) }
        }
        fun document(flags: Int = 0xf8, widthUnit: Int = 1, width: Float = 16f,
            clear: Int = 1, version: Int = 74): ByteArray {
            out.write(byteArrayOf(68, 80, 82, version.toByte())); u32(0); u32(1)
            byte(2); string("Body"); string(""); string(""); u32(1)
            byte(12); byte(0); byte(0); u32(0); byte(0); string(""); string("")
            byte(1); byte(12); u16(3); byte(0); u32(900) // table geometry retains cell padding and legacy width
            u32(1); span("Caption")
            u32(1); u32(1); byte(0); u16(1); u16(1); byte(0)
            u32(1); span("Body link", "Target"); byte(0); byte(0)
            byte(1); byte(2); repeat(4) { length(7f) } // independent CellStyle padding
            mark("presence"); byte(1); mark("flags"); byte(flags)
            if (flags and 1 != 0) string("#f9f9f9")
            if (flags and 2 != 0) byte(0)
            if (flags and 4 != 0) byte(0)
            if (flags and 8 != 0) repeat(4) { length(.4f, 1) }
            if (flags and 16 != 0) byte(0)
            if (flags and 32 != 0) { mark("unit"); byte(widthUnit); mark("width"); f32(width) }
            if (flags and 64 != 0) { mark("padding"); repeat(4) { length(.16f, 1) } }
            if (flags and 128 != 0) { mark("clear"); byte(clear) }
            if (version >= 74) byte(0) // authoritative rich table caption absent
            string(""); string(""); byte(0) // block anchor/fallback/alignment
            if (version >= 73) byte(0) // paragraph style absent
            if (version >= 74) { byte(0); byte(0) } // figure and flow absent
            repeat(5) { u32(0) }
            return out.toByteArray()
        }
    }
    private fun decode(bytes: ByteArray) = BlobDecoder.decode(bytes, "Table", "language", "English", "en")
        .sections.single().blocks.single().table!!

    @Test fun newFieldsAndEveryUnitRetainOldGeometryBodyCaptionAndCellPadding() {
        for (unit in 0..2) for (width in listOf(0f, 16f, 100f, 150f)) for (clear in 0..3) {
            val table = decode(Wire().document(widthUnit = unit, width = width, clear = clear))
            assertEquals(StyleWidth(StyleWidthUnit.entries[unit], width), table.style!!.width)
            assertEquals(FigureClear.entries[clear], table.style!!.clear)
            assertEquals(.16f, table.style!!.padding!!.left.value, 0f)
            assertEquals(StyleLengthUnit.Em, table.style!!.padding!!.left.unit)
            assertEquals(TableFloatSide.Left, table.style!!.floatSide)
            assertEquals(.4f, table.style!!.margins!!.right.value, 0f)
            assertEquals(TableWidth(TableWidthUnit.Px, 900), table.geometry!!.width)
            assertEquals(3, table.geometry!!.cellPadding)
            assertEquals(7f, table.rows[0][0].style!!.padding!!.left.value, 0f)
            assertEquals("Caption", textOf(table.caption))
            assertEquals("Target", table.rows[0][0].spans.single().target)
        }
        for (flag in listOf(32, 64, 128)) {
            val table = decode(Wire().document(flags = flag, width = 0f, clear = 0))
            assertEquals(flag == 32, table.style!!.width != null)
            assertEquals(flag == 64, table.style!!.padding != null)
            assertEquals(flag == 128, table.style!!.clear != null)
        }
    }

    @Test fun literalTableStyleRejectsBadTagsNumbersMissingPayloadAndEarlierVersionBits() {
        val wire = Wire(); val valid = wire.document()
        fun changed(name: String, value: Int): ByteArray = valid.copyOf().also { it[wire.marks.getValue(name)] = value.toByte() }
        for ((name, value) in listOf("presence" to 2, "flags" to 0, "unit" to 3, "clear" to 4, "padding" to 2))
            assertThrows(RuntimeException::class.java) { decode(changed(name, value)) }
        for (number in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY)) {
            assertThrows(RuntimeException::class.java) { decode(Wire().document(width = number)) }
            val invalid = valid.copyOf(); val bits = number.toRawBits()
            repeat(4) { invalid[wire.marks.getValue("padding") + 1 + it] = (bits ushr (it * 8)).toByte() }
            assertThrows(RuntimeException::class.java) { decode(invalid) }
        }
        for (size in valid.indices) assertThrows(RuntimeException::class.java) { decode(valid.copyOf(size)) }
        assertThrows(RuntimeException::class.java) { decode(valid + byteArrayOf(0)) }
        for (version in 72..73) for (flag in listOf(32, 64, 128))
            assertThrows(RuntimeException::class.java) { decode(Wire().document(flags = flag, version = version)) }
        val old = decode(Wire().document(flags = 24, version = 73))
        val next = decode(Wire().document(flags = 24))
        assertEquals(old, next)
        assertNull(old.style!!.width); assertNull(old.style!!.padding); assertNull(old.style!!.clear)
    }
}
