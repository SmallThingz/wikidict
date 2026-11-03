package app.smallthingz.dict

import java.io.ByteArrayInputStream
import java.io.InputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class CountingInputTest {
    @Test fun bytesUsesBulkReadsAndHandlesShortReads() {
        val stream = ChunkedInput(byteArrayOf(1, 2, 3, 4, 5), chunkSize = 2)
        val input = CountingInput(stream)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5), input.bytes(5))
        assertEquals(5L, input.position)
        assertEquals(3, stream.bulkReads)
        assertEquals(0, stream.singleReads)
        assertEquals(-1, input.read())
        assertEquals(5L, input.position)
    }

    @Test fun zeroBulkReadFallsBackToSingleByteRead() {
        val stream = ChunkedInput(byteArrayOf(1, 2, 3), chunkSize = 2, zeroBulkReads = true)
        val input = CountingInput(stream)
        assertArrayEquals(byteArrayOf(1, 2, 3), input.bytes(3))
        assertEquals(3L, input.position)
        assertEquals(3, stream.singleReads)
    }

    @Test fun truncatedPayloadPreservesConsumedPosition() {
        for (zeroBulkReads in listOf(false, true)) {
            val input = CountingInput(ChunkedInput(byteArrayOf(1, 2, 3), 2, zeroBulkReads))
            try {
                input.bytes(4)
                fail("Expected truncated dictionary")
            } catch (error: IllegalArgumentException) {
                assertEquals("Truncated dictionary", error.message)
            }
            assertEquals(3L, input.position)
        }
    }

    @Test fun positionTracksBytesSingleReadsAndBothSkipPaths() {
        for (skipProgress in listOf(false, true)) {
            val input = CountingInput(ChunkedInput(byteArrayOf(1, 2, 3, 4, 5, 6), 2,
                skipProgress = skipProgress))
            assertArrayEquals(byteArrayOf(1, 2), input.bytes(2))
            assertEquals(2L, input.position)
            assertEquals(3, input.read())
            assertEquals(3L, input.position)
            input.skipFully(2)
            assertEquals(5L, input.position)
            assertArrayEquals(byteArrayOf(6), input.bytes(1))
            assertEquals(6L, input.position)
            assertArrayEquals(byteArrayOf(), input.bytes(0))
            assertEquals(6L, input.position)
        }
    }

    @Test fun bulkPayloadCanBeFollowedByTitleAndVaruint() {
        val input = CountingInput(ChunkedInput(byteArrayOf(9, 8, 65, 0, 0xac.toByte(), 2), 2))
        assertArrayEquals(byteArrayOf(9, 8), input.bytes(2))
        assertEquals("A", input.nul())
        assertEquals(4L, input.position)
        assertEquals(300L, input.varuint())
        assertEquals(6L, input.position)
    }

    private class ChunkedInput(
        bytes: ByteArray,
        private val chunkSize: Int,
        private val zeroBulkReads: Boolean = false,
        private val skipProgress: Boolean = true,
    ) : InputStream() {
        private val source = ByteArrayInputStream(bytes)
        var bulkReads = 0
            private set
        var singleReads = 0
            private set
        override fun read(): Int {
            singleReads++
            return source.read()
        }
        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            bulkReads++
            return if (zeroBulkReads) 0 else source.read(buffer, offset, minOf(length, chunkSize))
        }
        override fun skip(count: Long): Long = if (skipProgress) source.skip(count) else 0L
    }
}
