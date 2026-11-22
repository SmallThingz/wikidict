package app.smallthingz.dict

import java.io.File
import org.junit.Assert.*
import org.junit.Test
import org.tukaani.xz.LZMA2Options
import org.tukaani.xz.XZOutputStream

class BlobSourceTest {
    @Test fun seekReadsAcrossBlocksAndConcatenatedStreams() {
        val raw = ByteArray(200_000) { ((it * 31) % 251).toByte() }
        val file = File.createTempFile("wikidict-xz", ".xz")
        try {
            file.outputStream().use { out ->
                for (stream in 0..1) {
                    val xz = XZOutputStream(out, LZMA2Options(1))
                    repeat(5) { block -> xz.write(raw, stream * 100_000 + block * 20_000, 20_000); xz.endBlock() }
                    xz.finish()
                }
            }
            BlobSource(file).use { source ->
                assertTrue(source.compressed); assertEquals(raw.size.toLong(), source.length)
                for (offset in listOf(0, 19_990, 99_990, 150_000, 199_990, 4))
                    assertArrayEquals(raw.copyOfRange(offset, offset + 10), source.read(offset.toLong(), 10))
            }
            val truncated = file.readBytes().dropLast(5).toByteArray()
            file.writeBytes(truncated)
            assertThrows(Exception::class.java) { BlobSource(file).close() }
        } finally { file.delete() }
    }
    @Test fun rawRangesAreBounded() {
        val file = File.createTempFile("wikidict-raw", ".wikblb")
        try {
            file.writeBytes(ByteArray(100) { it.toByte() })
            BlobSource(file).use { source ->
                assertFalse(source.compressed)
                assertArrayEquals(byteArrayOf(4,5,6,7), source.read(4,4))
                assertThrows(IllegalArgumentException::class.java) { source.read(98,4) }
            }
        } finally { file.delete() }
    }
}
