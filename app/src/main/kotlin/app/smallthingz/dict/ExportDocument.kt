package app.smallthingz.dict

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

object ExportDocument {
    const val MAX_BYTES = 64 * 1024 * 1024

    fun compiledJson(bytes: ByteArray): String {
        val decoder = StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return compiledJson(bytes, decoder)
    }

    private fun compiledJson(bytes: ByteArray, decoder: java.nio.charset.CharsetDecoder): String {
        require(bytes.size <= MAX_BYTES) { "Dictionary package is larger than 64 MiB." }
        val text = decoder.decode(ByteBuffer.wrap(bytes)).toString()
        require(text.trimStart().startsWith("{")) { "Compiled dictionary packages must be JSON." }
        return text
    }

    fun decode(bytes: ByteArray): Results {
        val decoder = StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return ResultParser.parse(compiledJson(bytes, decoder))
    }
}
