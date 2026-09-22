package app.smallthingz.dict
import org.junit.Assert.*
import org.junit.Test
import java.util.Locale
class SpeechVoiceTest {
    private val jamaican = SpeechVoice("en-029", Locale.forLanguageTag("en-JM"), 300, false)
    private val british = SpeechVoice("en-gb-x-rp", Locale.UK, 300, false)
    @Test fun honorsConfiguredVoiceInsteadOfAlphabeticalDialect() {
        assertEquals(british, chooseSpeechVoice(listOf(jamaican, british), "en", british.name, Locale.forLanguageTag("en-AU")))
    }
    @Test fun offlineAndLanguageRequirementsOverrideDefault() {
        val cloud = british.copy(name = "cloud", network = true)
        assertEquals(jamaican, chooseSpeechVoice(listOf(cloud, jamaican), "en", "cloud", Locale.UK))
        assertNull(chooseSpeechVoice(listOf(cloud), "en", "cloud", Locale.UK))
        assertNull(chooseSpeechVoice(listOf(british), "fr", british.name, Locale.FRANCE))
        assertEquals(british, chooseSpeechVoice(listOf(jamaican, british), "en", null, Locale.UK))
    }
}
