package app.smallthingz.dict

import java.io.BufferedInputStream
import java.io.ByteArrayInputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

/** Host dispatch microbenchmark only; excludes input construction and disk/XZ/device work. */
class CountingInputBenchmarkTest {
    @Test fun matchedBufferedPayloadReads() {
        for ((recordSize, records) in listOf(4096 to 100, 262144 to 16)) {
            val payload = ByteArray(recordSize * records) { ((it * 31 + 17) and 255).toByte() }
            val expected = payload.copyOfRange(payload.size - recordSize, payload.size)
            fun sample(bulk: Boolean): Long {
                // Match the import buffer and keep construction outside the measured interval.
                val stream = BufferedInputStream(ByteArrayInputStream(payload), 256 * 1024)
                val results = arrayOfNulls<ByteArray>(records)
                val position: Long
                val elapsed: Long
                if (bulk) {
                    val input = CountingInput(stream)
                    val start = System.nanoTime()
                    repeat(records) { results[it] = input.bytes(recordSize); sink = results[it]!! }
                    elapsed = System.nanoTime() - start
                    position = input.position
                    input.close()
                } else {
                    val input = BaselineCountingInput(stream)
                    val start = System.nanoTime()
                    repeat(records) { results[it] = input.bytes(recordSize); sink = results[it]!! }
                    elapsed = System.nanoTime() - start
                    position = input.position
                    input.close()
                }
                assertEquals(payload.size.toLong(), position)
                results.forEach { assertArrayEquals(expected, it) }
                return elapsed
            }
            // Check every returned record outside timing, including content parity.
            CountingInput(BufferedInputStream(ByteArrayInputStream(payload), 256 * 1024)).use { current ->
                BaselineCountingInput(BufferedInputStream(ByteArrayInputStream(payload), 256 * 1024)).use { baseline ->
                    repeat(records) { index ->
                        val actual = current.bytes(recordSize)
                        assertArrayEquals(payload.copyOfRange(index * recordSize, (index + 1) * recordSize), actual)
                        assertArrayEquals(baseline.bytes(recordSize), actual)
                    }
                    assertEquals(payload.size.toLong(), current.position)
                    assertEquals(current.position, baseline.position)
                }
            }
            repeat(3) { sample(false); sample(true) }
            repeat(8) { index ->
                val baseline: Long
                val bulk: Long
                if (index % 2 == 0) {
                    baseline = sample(false)
                    bulk = sample(true)
                } else {
                    bulk = sample(true)
                    baseline = sample(false)
                }
                println("CountingInput host_dispatch record_bytes=$recordSize records=$records sample=$index baseline_ns=$baseline bulk_ns=$bulk")
            }
        }
    }

    companion object {
        @Volatile private var sink = ByteArray(0)
    }
}
