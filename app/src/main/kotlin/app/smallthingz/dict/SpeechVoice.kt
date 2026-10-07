package app.smallthingz.dict

import java.util.Locale

data class SpeechVoice(val name: String, val locale: Locale, val quality: Int, val network: Boolean, val installed: Boolean = true)

fun chooseSpeechVoice(voices: List<SpeechVoice>, language: String, defaultName: String?, deviceLocale: Locale): SpeechVoice? {
    val requested = Locale.forLanguageTag(language)
    if (requested.language.isBlank() || requested.language == "und") return null
    val local = voices.filter { !it.network && it.installed && it.locale.language == requested.language }
    local.firstOrNull { it.name == defaultName }?.let { return it }
    // The dictionary usually supplies only a language, not an accent. Preserve
    // user/device regional preference before considering quality or stable order.
    val preferred = if (requested.country.isNotEmpty()) requested else if (deviceLocale.language == requested.language) deviceLocale else requested
    return local.sortedWith(compareByDescending<SpeechVoice> { it.locale == preferred }
        .thenByDescending { preferred.country.isNotEmpty() && it.locale.country == preferred.country }
        .thenByDescending { it.locale.country.isEmpty() && it.locale.variant.isEmpty() }
        .thenByDescending { it.quality }.thenBy { it.name }).firstOrNull()
}
