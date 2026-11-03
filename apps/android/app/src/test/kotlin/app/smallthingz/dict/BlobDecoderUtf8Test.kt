package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import java.nio.charset.CharacterCodingException
import org.junit.Assert.*
import org.junit.Test

class BlobDecoderUtf8Test {
    // A minimal DPR2 entry with one display span exercises six independently
    // length-prefixed strings followed by all six empty trailing collections.
    private fun payload(fields: List<ByteArray>): ByteArray {
        require(fields.size == 6)
        val out = ByteArrayOutputStream()
        fun u32(value: Int) { repeat(4) { out.write(value ushr (it * 8) and 255) } }
        out.write("DPR2".toByteArray(Charsets.US_ASCII))
        u32(1)
        repeat(3) { out.write(0) } // text, normal, no style flags
        fields.forEach { u32(it.size); out.write(it) }
        repeat(6) { u32(0) } // sections, preamble, groups, section indices, references, media
        return out.toByteArray()
    }

    @Test fun independentUtf8FieldsPreserveEmptyUnicodeAndBidiContent() {
        val fields = listOf("العَرَبِيَّة\u2067😀\u2069", "", "é", "ar", "", "rtl")
        val entry = BlobDecoder.decode(payload(fields.map { it.toByteArray(Charsets.UTF_8) }), "fixture", "language", "Arabic", "ar")
        val span = entry.displayTitle.single()
        assertEquals(fields[0], span.text)
        assertEquals(fields[1], span.target)
        assertEquals(fields[2], span.trail)
        assertEquals(fields[3], span.language)
        assertEquals(fields[4], span.classes)
        assertEquals(fields[5], span.direction)
        assertTrue(entry.sections.isEmpty())
        assertTrue(entry.media.isEmpty())
    }

    @Test fun malformedUtf8IsRejectedAfterValidAndEmptyFields() {
        val valid = listOf("😀", "", "é", "ar", "", "rtl").map { it.toByteArray(Charsets.UTF_8) }
        for (invalid in listOf(byteArrayOf(0xc3.toByte()), byteArrayOf(0xc0.toByte(), 0xaf.toByte()), byteArrayOf(0xed.toByte(), 0xa0.toByte(), 0x80.toByte()))) {
            val fields = valid.toMutableList().apply { this[5] = invalid }
            assertThrows(CharacterCodingException::class.java) {
                BlobDecoder.decode(payload(fields), "fixture", "language", "Arabic", "ar")
            }
        }
        // A rejected entry cannot poison a later independent Reader.
        assertEquals("rtl", BlobDecoder.decode(payload(valid), "fixture", "language", "Arabic", "ar").displayTitle.single().direction)
    }
}
