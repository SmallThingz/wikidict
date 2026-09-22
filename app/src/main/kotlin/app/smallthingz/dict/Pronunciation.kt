package app.smallthingz.dict

/** Explicit English IPA subset for eSpeak's SSML phoneme alphabet. Reject rather than guess. */
object Pronunciation {
    const val espeakEngine = "com.reecedunn.espeak"
    private val phones = linkedMapOf(
        "t͡ʃ" to "tS", "d͡ʒ" to "dZ", "tʃ" to "tS", "dʒ" to "dZ",
        "aɪ" to "aI", "aʊ" to "aU", "eɪ" to "eI", "ɔɪ" to "OI", "əʊ" to "oU", "oʊ" to "oU",
        "ɪə" to "i@", "ɛə" to "e@", "ʊə" to "U@", "iː" to "i:", "uː" to "u:",
        "ɑː" to "A:", "ɔː" to "O:", "ɜː" to "3:",
        "p" to "p", "b" to "b", "t" to "t", "d" to "d", "k" to "k", "ɡ" to "g", "g" to "g",
        "f" to "f", "v" to "v", "θ" to "T", "ð" to "D", "s" to "s", "z" to "z", "ʃ" to "S", "ʒ" to "Z",
        "h" to "h", "m" to "m", "n" to "n", "ŋ" to "N", "l" to "l", "ɹ" to "r", "r" to "r", "j" to "j", "w" to "w",
        "æ" to "a", "ɛ" to "E", "ɪ" to "I", "ɒ" to "0", "ʌ" to "V", "ʊ" to "U", "ə" to "@", "i" to "i", "u" to "u:",
        "ˈ" to "'", "ˌ" to ",", "." to "", " " to " "
    )
    fun ssml(ipa: String, language: String): String? {
        if (language != "en") return null
        val value = ipa.trim().let { if ((it.startsWith('/') && it.endsWith('/')) || (it.startsWith('[') && it.endsWith(']'))) it.substring(1, it.length - 1) else return null }
        if (value.isBlank() || value.length > 256) return null
        val out = StringBuilder(); var at = 0
        while (at < value.length) {
            val phone = phones.entries.firstOrNull { value.startsWith(it.key, at) } ?: return null
            out.append(phone.value); at += phone.key.length
        }
        return "<speak><phoneme alphabet=\"espeak\" ph=\"$out\"/></speak>"
    }
}
