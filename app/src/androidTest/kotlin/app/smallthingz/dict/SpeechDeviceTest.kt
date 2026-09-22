package app.smallthingz.dict

import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.Assert.*
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class SpeechDeviceTest {
    @Test fun offlineEngineSynthesizesWordsAndDistinctPhonemes() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val initialized = CountDownLatch(1)
        var status = TextToSpeech.ERROR
        val engine = TextToSpeech(context, { status = it; initialized.countDown() }, Pronunciation.espeakEngine)
        val files = mutableListOf<File>()
        try {
            assertTrue(initialized.await(20, TimeUnit.SECONDS)); assertEquals(TextToSpeech.SUCCESS, status)
            val voice = engine.voices.filter { !it.isNetworkConnectionRequired && it.locale.language == "en" }.sortedBy { it.name }.first()
            assertEquals(TextToSpeech.SUCCESS, engine.setVoice(voice))
            val results = listOf("cat", Pronunciation.ssml("/kæt/", "en")!!, Pronunciation.ssml("/dɒɡ/", "en")!!).mapIndexed { index, text ->
                val completed = CountDownLatch(1); var failed = false
                engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(id: String?) {}
                    override fun onDone(id: String?) { completed.countDown() }
                    @Deprecated("Android callback") override fun onError(id: String?) { failed = true; completed.countDown() }
                })
                val file = File(context.cacheDir, "speech-test-$index.wav"); files.add(file)
                assertEquals(TextToSpeech.SUCCESS, engine.synthesizeToFile(text, null, file, "$index"))
                assertTrue(completed.await(20, TimeUnit.SECONDS)); assertFalse(failed)
                val bytes = file.readBytes(); assertTrue("No synthesized audio for $text", bytes.size > 1000)
                assertEquals("RIFF", bytes.take(4).toByteArray().decodeToString())
                bytes
            }
            assertFalse("Different phonemes must produce different audio", results[1].contentEquals(results[2]))
        } finally { engine.shutdown(); files.forEach { it.delete() } }
    }
}
