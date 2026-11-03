package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import java.lang.management.ManagementFactory
import org.junit.Assert.assertEquals
import org.junit.Test

/** Temporary matched host microbenchmark; no Android/app latency claim. */
class BlobDecoderAllocationBenchmarkTest {
    companion object {
        @Volatile private var entrySink: Entry? = null
        private const val Iterations = 100
        private const val Samples = 8
    }

    private fun fixture(dense: Boolean): ByteArray {
        val out = ByteArrayOutputStream()
        fun u32(value: Int) { repeat(4) { out.write(value ushr (it * 8) and 255) } }
        fun string(value: String) {
            val bytes = value.toByteArray(Charsets.UTF_8)
            u32(bytes.size); out.write(bytes)
        }
        out.write("DPR2".toByteArray(Charsets.US_ASCII))
        u32(64)
        repeat(64) { index ->
            repeat(3) { out.write(0) } // text, normal, no style flags
            val fields = if (dense) listOf("العَرَبِيَّة😀é$index", "目的語$index", "é", "ar", "poem example", "rtl")
                else listOf("العَرَبِيَّة😀é$index", "", if (index % 4 == 0) "é" else "", "", "", "")
            fields.forEach(::string)
        }
        repeat(6) { u32(0) } // sections, preamble, semantic groups/indices, references, media
        return out.toByteArray()
    }

    private fun decode(candidate: Boolean, payload: ByteArray): Entry = if (candidate)
        BlobDecoder.decode(payload, "host-fixture", "language", "Arabic", "ar")
    else BaselineBlobDecoder.decode(payload, "host-fixture", "language", "Arabic", "ar")

    @Test fun matchedHostDecodeSamples() {
        val bean = ManagementFactory.getThreadMXBean() as? com.sun.management.ThreadMXBean
        val allocationBean = bean?.takeIf { it.isThreadAllocatedMemorySupported }?.let {
            if (!it.isThreadAllocatedMemoryEnabled) runCatching { it.isThreadAllocatedMemoryEnabled = true }
            it.takeIf { enabled -> enabled.isThreadAllocatedMemoryEnabled }
        }
        val thread = Thread.currentThread().id
        println("HOST_MICROBENCH only; authored DPR2; 64 spans; iterations=$Iterations; allocationSupported=${allocationBean != null}; java=${System.getProperty("java.version")}")
        for (dense in listOf(false, true)) {
            val payload = fixture(dense)
            val label = if (dense) "dense" else "mixed-empty"
            assertEquals("Full Entry equality for $label", decode(false, payload), decode(true, payload))
            // Both implementations see the same fixture and equal warmup counts.
            repeat(100) { index ->
                entrySink = decode(index % 2 == 0, payload)
                entrySink = decode(index % 2 != 0, payload)
            }
            repeat(Samples) { sample ->
                val order = if (sample % 2 == 0) listOf(false, true) else listOf(true, false)
                for (candidate in order) {
                    val allocatedBefore = allocationBean?.getThreadAllocatedBytes(thread)
                    val start = System.nanoTime()
                    repeat(Iterations) { entrySink = decode(candidate, payload) }
                    val nanos = System.nanoTime() - start
                    val allocatedAfter = allocationBean?.getThreadAllocatedBytes(thread)
                    val allocated = if (allocatedBefore != null && allocatedAfter != null && allocatedBefore >= 0 && allocatedAfter >= 0)
                        (allocatedAfter - allocatedBefore).toString() else "unsupported"
                    println("HOST_DECODE fixture=$label sample=$sample order=${if (candidate == order.first()) 0 else 1} implementation=${if (candidate) "candidate" else "baseline"} iterations=$Iterations elapsedNs=$nanos allocatedBytes=$allocated")
                }
            }
        }
    }
}
