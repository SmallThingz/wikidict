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
        val undefined = SpeechVoice("undefined",Locale.ROOT,300,false)
        for (language in listOf("", "und", "x-private")) assertNull(chooseSpeechVoice(listOf(undefined,british),language,undefined.name,Locale.UK))
        val cloud = british.copy(name = "cloud", network = true)
        assertEquals(jamaican, chooseSpeechVoice(listOf(cloud, jamaican), "en", "cloud", Locale.UK))
        assertNull(chooseSpeechVoice(listOf(cloud), "en", "cloud", Locale.UK))
        assertNull(chooseSpeechVoice(listOf(british), "fr", british.name, Locale.FRANCE))
        assertEquals(british, chooseSpeechVoice(listOf(jamaican, british), "en", null, Locale.UK))
    }
    @Test fun failedInitializationWithoutPendingRequestPreservesErrorAndReleasesEngine() {
        val releases = mutableListOf<String>()
        // Exercise the completion policy with no request, including an existing reader error.
        for (currentError in listOf(null, "This entry has no identified language for speech.")) {
            var error = currentError
            finishFailedSpeechInitialization(false, { error = "engine failed" }, { releases += "release" })
            assertEquals(currentError, error)
        }
        assertEquals(listOf("release", "release"), releases)
    }
    @Test fun failedInitializationWithPendingRequestPublishesAndAlwaysReleasesEngine() {
        val steps = mutableListOf<String>()
        var active: String? = "requested word"
        var error: String? = null
        finishFailedSpeechInitialization(true, {
            error = "engine failed"
            active = null
            steps += "publish"
        }, { steps += "release" })
        assertEquals("engine failed", error)
        assertNull(active)
        assertEquals(listOf("publish", "release"), steps)
        val expected = IllegalStateException("owned publication failure")
        try {
            finishFailedSpeechInitialization(true, { throw expected }, { steps += "release-after-error" })
            fail("Expected the original publication failure")
        } catch (actual: IllegalStateException) {
            assertSame(expected, actual)
        }
        assertEquals(listOf("publish", "release", "release-after-error"), steps)
    }
}
