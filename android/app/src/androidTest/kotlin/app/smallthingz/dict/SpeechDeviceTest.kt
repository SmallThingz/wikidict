package app.smallthingz.dict

import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.Assert.*
import java.io.File
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class SpeechDeviceTest {
    @Test fun offlineSpeechRespectsConfiguredVoiceAndSpeaksActualWords() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val initialized = CountDownLatch(1)
        var status = TextToSpeech.ERROR
        val engine = TextToSpeech(context, { status = it; initialized.countDown() })
        val files = mutableListOf<File>()
        try {
            assertTrue(initialized.await(20, TimeUnit.SECONDS)); assertEquals(TextToSpeech.SUCCESS, status)
            val selected = chooseSpeechVoice(engine.voices.map { SpeechVoice(it.name,it.locale,it.quality,it.isNetworkConnectionRequired, "notInstalled" !in it.features.orEmpty()) }, "en", engine.defaultVoice?.name, Locale.getDefault())!!
            val voice = engine.voices.first { it.name == selected.name }
            assertFalse(voice.isNetworkConnectionRequired)
            if (engine.defaultVoice?.locale?.language == "en" && engine.defaultVoice?.isNetworkConnectionRequired == false) assertEquals(engine.defaultVoice.name, voice.name)
            assertEquals(TextToSpeech.SUCCESS, engine.setVoice(voice))
            for (word in listOf("elephant", "cat", "January")) {
                val completed = CountDownLatch(1); var failed = false
                engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(id: String?) {}
                    override fun onDone(id: String?) { completed.countDown() }
                    @Deprecated("Android callback") override fun onError(id: String?) { failed = true; completed.countDown() }
                })
                val file = File(context.cacheDir, "speech-test-$word.wav"); files.add(file)
                assertEquals(TextToSpeech.SUCCESS, engine.synthesizeToFile(word, null, file, word))
                assertTrue(completed.await(20, TimeUnit.SECONDS)); assertFalse(failed)
                val bytes = file.readBytes(); assertTrue("No synthesized audio for $word", bytes.size > 1000)
                assertEquals("RIFF", bytes.take(4).toByteArray().decodeToString())
                android.util.Log.i("WikidictVoiceAudit", "$word: voice=${voice.name} bytes=${bytes.size}")
            }
        } finally { engine.shutdown(); files.forEach { it.delete() } }
    }
}
