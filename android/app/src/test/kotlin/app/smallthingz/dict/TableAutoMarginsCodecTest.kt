package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

/** Literal M documents; no producer or JSON path is involved. These controls are unrun. */
class TableAutoMarginsCodecTest {
    private class Wire {
        val out = ByteArrayOutputStream()
        val marks = linkedMapOf<String, Int>()
        fun byte(value: Int) { out.write(value) }
        fun u16(value: Int) { repeat(2) { byte(value ushr (it * 8)) } }
        fun u32(value: Int) { repeat(4) { byte(value ushr (it * 8)) } }
        fun f32(value: Float) = u32(value.toRawBits())
        fun string(value: String) { val raw = value.encodeToByteArray(); u32(raw.size); out.write(raw) }
        fun length(value: Float, unit: Int = 0) { byte(unit); f32(value) }
        fun span(text: String, target: String) {
            byte(1); byte(0); byte(0); string(text); string(target)
            repeat(5) { string("") }; repeat(6) { byte(0) }
        }
        fun table(prefix: String, extension: Int, oldMargins: Boolean, nested: Boolean,
            verticalTag: Int, leftTag: Int, rightTag: Int, number: Float, direction: Int) {
            byte(1); byte(0); u32(1); span("Caption $prefix", "caption-target-$prefix")
            u32(1); u32(1); byte(0); u16(1); u16(1); byte(0)
            u32(if (nested) 0 else 1)
            if (!nested) span("Body $prefix", "body-target-$prefix")
            if (nested) table("nested", 24, false, false, 1, 0, 0, .2f, 1) else byte(0)
            byte(0); byte(0) // ordered cell blocks and cell style absent
            byte(1); byte(32 or (if (oldMargins) 8 else 0))
            marks[prefix + "extension"] = out.size(); byte(extension)
            if (oldMargins) repeat(4) { length(3f) }
            byte(2); f32(70f) // width:70%, still independent of auto margins
            if (extension and 4 != 0) { f32(1.2f); byte(1) }
            if (extension and 8 != 0) {
                for ((side, tag) in listOf("top" to verticalTag, "right" to rightTag, "bottom" to 1, "left" to leftTag)) {
                    marks[prefix + side] = out.size(); byte(tag)
                    if (tag == 1) { marks[prefix + side + "unit"] = out.size(); length(number, 1) }
                }
            }
            if (extension and 16 != 0) { marks[prefix + "direction"] = out.size(); byte(direction) }
            byte(0) // rich caption absent
        }
        fun document(version: Int = 77, extension: Int = 24, oldMargins: Boolean = false,
            nested: Boolean = false, verticalTag: Int = 1, leftTag: Int = 0,
            rightTag: Int = 0, number: Float = .2f, direction: Int = 0): ByteArray {
            out.write(byteArrayOf(68, 80, 82, version.toByte())); u32(0); u32(1)
            byte(2); string("Body"); string(""); string(""); u32(1)
            byte(12); byte(0); byte(0); u32(0); byte(0); string(""); string("")
            table("root", extension, oldMargins, nested, verticalTag, leftTag, rightTag, number, direction)
            string(""); string(""); byte(0); byte(0); byte(0); byte(0)
            repeat(5) { u32(0) }
            return out.toByteArray()
        }
    }
    private fun read(bytes: ByteArray) = BlobDecoder.decode(bytes, "auto table", "language", "Russian", "ru")
        .sections.single().blocks.single().table!!

    @Test fun completeMDocumentRetainsWidthCaptionBodyActionAndTailOrder() {
        val table = read(Wire().document(extension = 28))
        assertEquals(StyleWidth(StyleWidthUnit.Percent, 70f), table.style!!.width)
        assertEquals(ComputedLineHeight(1.2f, FontScaleBasis.NormalBody), table.style!!.lineHeight)
        assertNull(table.style!!.margins)
        assertEquals(TableContainingDirection.Ltr, table.style!!.containingDirection)
        val margins = table.style!!.marginValues!!
        assertEquals(ContainerMargin.Auto, margins.left); assertEquals(ContainerMargin.Auto, margins.right)
        assertEquals(ContainerMargin.Length(StyleLength(StyleLengthUnit.Em, .2f)), margins.top)
        assertEquals(margins.top, margins.bottom)
        assertEquals("Caption root", table.caption.single().text)
        assertEquals("caption-target-root", table.caption.single().target)
        assertEquals("Body root", table.rows.single().single().spans.single().text)
        assertEquals("body-target-root", table.rows.single().single().spans.single().target)
        val nested = read(Wire().document(nested = true)).rows.single().single().nestedTable!!
        assertEquals(margins, nested.style!!.marginValues)
        assertEquals(TableContainingDirection.Rtl, nested.style!!.containingDirection)
        assertEquals("body-target-nested", nested.rows.single().single().spans.single().target)
    }

    @Test fun malformedDomainTagsUnknownBitsAndTruncationRefuse() {
        val wire = Wire(); val valid = wire.document()
        fun mutate(mark: String, value: Int) = valid.copyOf().also { it[wire.marks.getValue(mark)] = value.toByte() }
        for (bits in listOf(8, 16, 32, 128, 255))
            assertThrows(RuntimeException::class.java) { read(mutate("rootextension", bits)) }
        for (tag in listOf(2, 255))
            assertThrows(RuntimeException::class.java) { read(mutate("rootdirection", tag)) }
        for (tag in listOf(2, 255))
            assertThrows(RuntimeException::class.java) { read(mutate("rootleft", tag)) }
        assertThrows(RuntimeException::class.java) { read(mutate("roottopunit", 2)) }
        assertThrows(RuntimeException::class.java) { read(Wire().document(verticalTag = 0)) }
        assertThrows(RuntimeException::class.java) { read(Wire().document(leftTag = 1, rightTag = 1)) }
        assertThrows(RuntimeException::class.java) { read(Wire().document(oldMargins = true)) }
        for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY))
            assertThrows(RuntimeException::class.java) { read(Wire().document(number = value)) }
        for (size in valid.indices) assertThrows(RuntimeException::class.java) { read(valid.copyOf(size)) }
        assertThrows(RuntimeException::class.java) { read(valid + byteArrayOf(0)) }
    }

    @Test fun kAndLKeepTheirMaskAndAbsentPathKeepsLegacyNumericMargins() {
        for (version in listOf(75, 76))
            assertThrows(RuntimeException::class.java) { read(Wire().document(version = version)) }
        val k = read(Wire().document(version = 75, extension = 0, oldMargins = true))
        val m = read(Wire().document(extension = 0, oldMargins = true))
        assertEquals(k, m); assertNull(m.style!!.marginValues)
        assertNull(m.style!!.containingDirection)
        assertEquals(3f, m.style!!.margins!!.left.value, 0f)
        assertEquals("body-target-root", m.rows.single().single().spans.single().target)
    }
}
