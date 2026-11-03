package app.smallthingz.dict

import java.io.File
import java.io.InputStream
import java.io.Closeable
import org.tukaani.xz.SeekableFileInputStream
import org.tukaani.xz.SeekableInputStream
import org.tukaani.xz.SeekableXZInputStream

/** Logical offsets are identical for raw and XZ storage; no expanded file is written. */
class BlobSource(file: File) : Closeable {
    private val source: SeekableInputStream
    val length: Long
    val compressed: Boolean
    init {
        val raw = SeekableFileInputStream(file)
        try {
            val magic = ByteArray(6)
            val n = raw.read(magic)
            raw.seek(0)
            compressed = n == 6 && magic.contentEquals(byteArrayOf(0xfd.toByte(), 0x37, 0x7a, 0x58, 0x5a, 0))
            source = if (compressed) SeekableXZInputStream(raw, 128 * 1024) else raw
            length = source.length()
            require(length in 9..32L * 1024 * 1024 * 1024) { "Dictionary size is unsupported" }
        } catch (error: Throwable) { raw.close(); throw error }
    }
    fun stream(): InputStream = source
    fun read(offset: Long, length: Int): ByteArray {
        require(offset >= 0 && length in 4..128 * 1024 * 1024 && offset <= this.length - length) { "Invalid record range" }
        source.seek(offset)
        val bytes = ByteArray(length)
        var position = 0
        while (position < bytes.size) {
            val n = source.read(bytes, position, bytes.size - position)
            require(n > 0) { "Truncated dictionary" }
            position += n
        }
        return bytes
    }
    override fun close() = source.close()
}
