package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

class TableCellDecoderTest {
    private class Wire {
        val output = ByteArrayOutputStream()
        fun byte(value: Int) { output.write(value) }
        fun short(value: Int) { byte(value); byte(value ushr 8) }
        fun int(value: Int) { repeat(4) { byte(value ushr (8 * it)) } }
        fun float(value: Float) = int(value.toRawBits())
        fun text(value: String) { val bytes = value.encodeToByteArray(); int(bytes.size); output.write(bytes) }
        fun length(unit: Int, value: Float) { byte(unit); float(value) }
        fun border(tag: Int, width: Float = 0f, color: String = "#0000ff") {
            byte(tag); if (tag != 0) { length(0, width); text(color) }
        }
    }
    private fun fixture(version: Char = 'K', style: Wire.() -> Unit): ByteArray = Wire().apply {
        byte('D'.code); byte('P'.code); byte('R'.code); byte(version.code)
        int(0) // display spans
        int(1); byte(2); text("Controlled"); text(""); text("")
        int(1); byte(12); byte(0); byte(0); int(0); byte(0); text(""); text("")
        byte(1); byte(0); int(0); int(1); int(1) // table, geometry, caption, row, cell
        byte(0); short(1); short(1); byte(0); int(0); byte(0); byte(0)
        byte(1); style()
        byte(0); byte(0) // table style, rich caption
        text(""); text(""); byte(0); byte(0); byte(0); byte(0)
        repeat(5) { int(0) } // preamble, lexemes, indices, references, media
    }.output.toByteArray()
    private fun read(bytes: ByteArray): CellStyle = BlobDecoder.decode(bytes, "word", "language", "English", "en")
        .sections.single().blocks.single().table!!.rows.single().single().style!!

    @Test fun fullKCellTailPreservesPhysicalEdgesAndZeroWidthWithoutChangingOldFields() {
        val bytes = fixture {
            byte(63); border(1, 1f, "#ff0000")
            listOf(3f, 3f, 4f, 3f).forEach { length(0, it) }; byte(1)
            byte(15); border(0); border(1, 2f); border(2, 4f); border(0)
            length(1, .3f); byte(0); float(0f)
        }
        val style = read(bytes)
        assertEquals(StyleBorder.Solid(StyleLength(StyleLengthUnit.Px, 1f), "#ff0000"), style.border)
        assertEquals(4f, style.padding!!.bottom.value, 0f); assertEquals(CellTextAlign.Center, style.textAlign)
        assertEquals(CellBorder.None, style.borderEdges!!.top)
        assertEquals(CellBorder.Double(StyleLength(StyleLengthUnit.Px, 4f), "#0000ff"), style.borderEdges!!.bottom)
        assertEquals(.3f, style.letterSpacing!!.value, 0f)
        assertEquals(StyleWidth(StyleWidthUnit.Px, 0f), style.width)
        assertThrows(Exception::class.java) { read(bytes.copyOf().also { it[3] = 'J'.code.toByte() }) }
        assertThrows(Exception::class.java) { read(bytes + byteArrayOf(0)) }
    }

    @Test fun earlierHeaderKeepsOldUniformBorderAndAbsentNewFields() {
        val old = read(fixture('J') { byte(1); border(0) })
        assertEquals(StyleBorder.None, old.border)
        assertNull(old.borderEdges); assertNull(old.letterSpacing); assertNull(old.width)
        assertEquals(old, read(fixture { byte(1); border(0) }))
    }

    @Test fun malformedKFlagsEdgesTagsColorsLengthsAndWidthRefuse() {
        val invalid: List<Wire.() -> Unit> = listOf(
            { byte(0) }, { byte(64) }, { byte(128) },
            { byte(8); byte(0) }, { byte(8); byte(16) }, { byte(8); byte(1); byte(3) },
            { byte(8); byte(1); border(2, 4f, "#ABCDEF") },
            { byte(16); length(1, -1f) }, { byte(16); length(1, Float.NaN) },
            { byte(32); byte(3); float(1f) }, { byte(32); byte(0); float(-1f) },
            { byte(32); byte(2); float(Float.POSITIVE_INFINITY) },
        )
        invalid.forEach { payload -> assertThrows(Exception::class.java) { read(fixture(style = payload)) } }
        val overOneHundred = read(fixture { byte(32); byte(2); float(200f) })
        assertEquals(StyleWidth(StyleWidthUnit.Percent, 200f), overOneHundred.width)
    }
}
