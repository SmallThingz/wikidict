package app.smallthingz.dict

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

object ExportDocument {
    const val MAX_BYTES = 64 * 1024 * 1024
    private const val OPEN = "<script id=\"dict-data\" type=\"application/json\">"
    private const val CLOSE = "</script>"

    fun decode(bytes: ByteArray): Results {
        require(bytes.size <= MAX_BYTES) { "Export is larger than 64 MiB." }
        val decoder = StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        val text = decoder.decode(ByteBuffer.wrap(bytes)).toString()
        return ResultParser.parse(extractJson(text))
    }

    fun extractJson(text: String): String {
        val trimmed = text.trimStart()
        if (trimmed.startsWith("{")) return trimmed
        val start = text.indexOf(OPEN)
        require(start >= 0) { "This HTML file is not a Dict export." }
        val bodyStart = start + OPEN.length
        val end = text.indexOf(CLOSE, bodyStart)
        require(end >= bodyStart) { "The Dict export is incomplete." }
        return text.substring(bodyStart, end)
    }
}
