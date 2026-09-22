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
    fun play(context: Context, word: String, language: String, ipa: String? = null) {
        val key = ipa ?: word
        if (active == key) { stop(); return }
        stop(); MediaPlayback.stop(); error = null; active = key
        val requestId = (++utterance).toString()
        val request = request@{
            val tts = engine ?: return@request
            val locale = Locale.forLanguageTag(language)
            val voice = tts.voices.orEmpty().filter { !it.isNetworkConnectionRequired && it.locale.language == locale.language && "notInstalled" !in it.features.orEmpty() }
                .sortedWith(compareByDescending<android.speech.tts.Voice> { it.locale == locale }.thenByDescending { it.quality }.thenBy { it.name }).firstOrNull()
            if (voice == null || tts.setVoice(voice) == TextToSpeech.ERROR) {
                error = "Install an offline voice for ${locale.getDisplayLanguage()} in speech settings."; active = null
                return@request
            }
            val text = if (ipa == null) word else {
                val phonemes = Pronunciation.ssml(ipa, language)
                if (tts.defaultEngine != Pronunciation.espeakEngine || phonemes == null) {
                    error = "This transcription needs a supported eSpeak voice. The word speaker uses your local voice."; active = null
                    return@request
                }
                phonemes
            }
            if (tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, requestId) == TextToSpeech.ERROR) { error = "The local voice could not speak."; active = null }
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
