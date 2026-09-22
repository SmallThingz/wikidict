package app.smallthingz.dict

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.compose.runtime.*
import java.util.Locale

/** A local Android speech service, never a network voice or dictionary execution engine. */
object SpeechPlayback {
    private var engine: TextToSpeech? = null
    private var ready = false
    private var generation = 0L
    private var utterance = 0L
    private var pending: (() -> Unit)? = null
    private val main = Handler(Looper.getMainLooper())
    var active by mutableStateOf<String?>(null); private set
    var error by mutableStateOf<String?>(null); private set
    fun stop() { utterance++; pending = null; engine?.stop(); active = null }
    fun close() { generation++; stop(); engine?.shutdown(); engine = null; ready = false }
    fun play(context: Context, word: String, language: String) {
        val key = word
        if (active == key) { stop(); return }
        stop(); MediaPlayback.stop(); error = null; active = key
        val requestId = (++utterance).toString()
        val request = request@{
            val tts = engine ?: return@request
            val locale = Locale.forLanguageTag(language)
            val voices = tts.voices.orEmpty()
            val selected = chooseSpeechVoice(voices.map { SpeechVoice(it.name, it.locale, it.quality, it.isNetworkConnectionRequired, "notInstalled" !in it.features.orEmpty()) }, language, tts.defaultVoice?.name, Locale.getDefault())
            val voice = voices.firstOrNull { it.name == selected?.name }
            if (voice == null || tts.setVoice(voice) == TextToSpeech.ERROR) {
                error = "Install an offline voice for ${locale.getDisplayLanguage()} in speech settings."; active = null
                return@request
            }
            if (tts.speak(word, TextToSpeech.QUEUE_FLUSH, null, requestId) == TextToSpeech.ERROR) { error = "The local voice could not speak."; active = null }
        }
        if (ready) request() else {
            pending = request
            if (engine == null) {
                val attempt = generation
                engine = TextToSpeech(context.applicationContext) { status -> main.post {
                if (attempt != generation) return@post
                if (status == TextToSpeech.SUCCESS) {
                    ready = true
                    engine?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                        override fun onStart(id: String?) {}
                        override fun onDone(id: String?) { main.post { if (utterance.toString() == id) active = null } }
                        @Deprecated("Android callback") override fun onError(id: String?) { main.post { if (utterance.toString() == id) { active = null; error = "The local voice could not speak." } } }
                    })
                    val next = pending; pending = null; next?.invoke()
                } else { error = "Install a local text-to-speech engine in speech settings."; active = null; pending = null; engine?.shutdown(); engine = null }
            } }
            }
        }
    }
}
