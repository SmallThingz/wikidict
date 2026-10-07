package app.smallthingz.dict

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.CodingErrorAction
import java.time.LocalDate
import java.time.format.DateTimeFormatter

/** An acquisition scope is explicit in the published filename, never guessed from a language. */
internal fun dictionaryEdition(filename: String): String {
    val match = Regex("^([a-z0-9_-]+wiktionary)-([0-9]{8})-([0-9a-f]{64}|aliases|supplemental|thesaurus|citations|reconstruction|rhymes|sign-gloss)\\.wikblb(?:\\.xz)?$").matchEntire(filename) ?: return ""
    if (runCatching { LocalDate.parse(match.groupValues[2], DateTimeFormatter.BASIC_ISO_DATE) }.isFailure) return ""
    return match.groupValues[1] + "-" + match.groupValues[2]
}

internal fun validateDictionaryFilename(filename: String, kind: String, heading: String) {
    val edition = dictionaryEdition(filename)
    if (edition.isEmpty()) return
    val actual = filename.removePrefix("$edition-").removeSuffix(".xz").removeSuffix(".wikblb")
    val expected = when (kind) {
        "language" -> java.security.MessageDigest.getInstance("SHA-256").digest(heading.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
        "alias" -> "aliases"
        "sign_gloss" -> "sign-gloss"
        else -> kind
    }
    require(actual == expected) { "Dictionary filename does not match its compiled header" }
}

data class Redirect(val source: String, val target: String, val fragment: String, val followed: Boolean)

internal data class CompiledAlias(
    val sourceNamespace: Long, val sourceKind: String, val sourceTitle: String, val sourceKey: String,
    val xmlTarget: String, val targetTitle: String, val targetNamespace: Long?, val targetKind: String?,
    val targetKey: String, val fragment: String, val presentation: ByteArray,
) {
    fun entry(): Entry = BlobDecoder.decode(presentation, sourceTitle, "alias", null, "")
    fun redirect(followed: Boolean) = Redirect(sourceTitle, targetTitle, fragment, followed)
}

/** DAL1 holds one direct edge plus a compiled DPR2 redirect page; there is no source evaluator. */
internal object AliasDecoder {
    fun decode(bytes: ByteArray, directoryKey: String): CompiledAlias {
        val r = Reader(bytes)
        require(r.take(4).contentEquals("DAL1".toByteArray())) { "Invalid compiled redirect" }
        val sourceNamespace = r.u32()
        val sourceTag = r.byte()
        require(sourceTag in 1..7)
        val sourceKind = blobKind(sourceTag)
        val hasNamespace = r.byte()
        require(hasNamespace in 0..1)
        val namespace = r.u32()
        require(hasNamespace == 1 || namespace == 0L)
        val targetNamespace = namespace.takeIf { hasNamespace == 1 }
        val targetTag = r.byte()
        require(targetTag in 0..7)
        val targetKind = targetTag.takeIf { it != 0 }?.let(::blobKind)
        val sourceTitle = r.string()
        val sourceKey = r.string()
        val xmlTarget = r.string()
        val targetTitle = r.string()
        val targetKey = r.string()
        val fragment = r.string()
        val presentation = r.field()
        require(!r.buffer.hasRemaining())
        require((sourceKind == "language") == (sourceNamespace == 0L))
        if (targetKind != null) {
            require(targetNamespace != null && (targetKind == "language") == (targetNamespace == 0L))
            require(targetKey.isNotEmpty())
        } else require(targetKey.isEmpty())
        for (s in listOf(sourceTitle, sourceKey, xmlTarget, targetTitle)) require(s.isNotEmpty() && '\u0000' !in s)
        require('\u0000' !in targetKey && '\u0000' !in fragment && fragment.toByteArray().size <= 255)
        fun key(kind: String, title: String): String {
            if (kind == "language" || kind == "supplemental") return title
            require(':' in title)
            return title.substringAfter(':')
        }
        require(sourceKey == key(sourceKind, sourceTitle))
        if (targetKind != null) require(targetKey == key(targetKind, targetTitle))
        require(directoryKey == "$sourceTag\t$sourceKey") { "Redirect index does not match its identity" }
        require(presentation.isNotEmpty())
        return CompiledAlias(sourceNamespace, sourceKind, sourceTitle, sourceKey, xmlTarget, targetTitle,
            targetNamespace, targetKind, targetKey, fragment, presentation).also { it.entry() }
    }

    private class Reader(bytes: ByteArray) {
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        fun byte(): Int { require(buffer.hasRemaining()); return buffer.get().toInt() and 255 }
        fun u32(): Long { require(buffer.remaining() >= 4); return buffer.int.toLong() and 0xffffffffL }
        fun take(size: Int): ByteArray { require(size in 0..buffer.remaining()); return ByteArray(size).also { buffer.get(it) } }
        fun field(): ByteArray {
            var length = 0L
            var shift = 0
            while (true) {
                val value = byte()
                require(shift <= 28)
                length = length or ((value and 127).toLong() shl shift)
                if (value and 128 == 0) {
                    require((shift == 0 || value != 0) && length <= buffer.remaining())
                    return take(length.toInt())
                }
                shift += 7
            }
        }
        fun string(): String = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(field())).toString()
    }
}
