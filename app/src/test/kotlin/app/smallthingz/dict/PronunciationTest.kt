package app.smallthingz.dict
import org.junit.Test
import org.junit.Assert.*
class PronunciationTest {
    @Test fun convertsOnlyExplicitSupportedPhonemes() {
        assertEquals("<speak><phoneme alphabet=\"espeak\" ph=\"kat\"/></speak>", Pronunciation.ssml("/kæt/", "en"))
        assertTrue(Pronunciation.ssml("/ˈdʒæn.ju.ə.ɹi/", "en")!!.contains("'dZan"))
        assertNull(Pronunciation.ssml("/kʰæt/", "en"))
        assertNull(Pronunciation.ssml("/kæt/", "fr"))
        assertNull(Pronunciation.ssml("cat", "en"))
        assertNull(Pronunciation.ssml("/<speak>/", "en"))
    }
}
