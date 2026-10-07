package app.smallthingz.dict

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.edit
import org.json.JSONArray
import org.json.JSONObject
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel

data class SavedWord(
    val key: String, val title: String, val language: String?, val kind: String, val clue: String,
    val savedAt: Long = 0, val lastViewed: Long = 0, val views: Int = 1,
    val dictionary: String? = null, val recordKey: String? = null, val contextDictionary: String? = null, val edition: String? = null,
)
data class StudyStat(val right: Int = 0, val wrong: Int = 0, val last: Long = 0)
data class AppSettings(
    val darkMode: String = "system",
    val historyEnabled: Boolean = true,
    val historyLimit: Int = 100,
    val quizLength: Int = 10,
    val randomPool: String = "all",
    val collapsePronunciation: Boolean = true,
    val collapseEtymology: Boolean = true,
    val collapseOtherSections: Boolean = true,
    val collapseDetails: Boolean = true,
    val allowImages: Boolean = false,
    val allowAudio: Boolean = false,
    val mediaCacheMb: Int = 100,
)
data class LearningData(
    val history: List<SavedWord> = emptyList(),
    val bookmarks: List<SavedWord> = emptyList(),
    val study: Map<String, StudyStat> = emptyMap(),
    val settings: AppSettings = AppSettings(),
)
class LearningStore private constructor(context: Context) {
    companion object {
        @Volatile private var instance: LearningStore? = null
        fun get(context: Context): LearningStore = instance ?: synchronized(this) {
            instance ?: LearningStore(context.applicationContext).also { instance = it }
        }
    }
    private val prefs = context.getSharedPreferences("dict.learning.v1", Context.MODE_PRIVATE)
    var data by mutableStateOf(load())
        private set

    fun record(entry: Entry) {
        val recorded = data.recordEntry(entry, System.currentTimeMillis())
        if (recorded != data) update(recorded)
    }

    fun toggleBookmark(entry: Entry) {
        val word = entry.saved(System.currentTimeMillis())
        val exists = data.bookmarks.any { it.key == word.key }
        update(data.copy(bookmarks = if (exists) data.bookmarks.filterNot { it.key == word.key }
        else listOf(word.copy(savedAt = System.currentTimeMillis())) + data.bookmarks))
    }

    fun removeHistory(key: String) = update(data.copy(history = data.history.filterNot { it.key == key }))
    fun removeBookmark(key: String) = update(data.copy(bookmarks = data.bookmarks.filterNot { it.key == key }))
    fun clearHistory() = update(data.copy(history = emptyList()))
    fun clearStudy() = update(data.copy(study = emptyMap()))
    fun answer(key: String, right: Boolean) {
        val old = data.study[key] ?: StudyStat()
        val next = old.copy(
            right = old.right + if (right) 1 else 0,
            wrong = old.wrong + if (right) 0 else 1,
            last = System.currentTimeMillis(),
        )
        update(data.copy(study = data.study + (key to next)))
    }

    fun updateSettings(transform: (AppSettings) -> AppSettings) {
        val transformed = transform(data.settings)
        val next = transformed.copy(
            historyLimit = transformed.historyLimit.coerceIn(1, 100_000),
            quizLength = transformed.quizLength.coerceIn(3, 50),
            mediaCacheMb = transformed.mediaCacheMb.coerceIn(0, 4096),
        )
        update(data.copy(settings = next, history = data.history.take(next.historyLimit)))
    }

    fun isBookmarked(entry: Entry) = data.bookmarks.any { it.key == entry.key }

    fun pool(entries: List<Entry>): List<SavedWord> {
        val source = when (data.settings.randomPool) {
            "bookmarks" -> data.bookmarks
            "history" -> data.history
            else -> data.bookmarks + data.history + entries.map { it.saved(0) }
        }
        return source.distinctBy { it.key }
    }

    // One writer preserves update order; serialization never runs on the UI thread.
    private val pending = Channel<LearningData>(Channel.CONFLATED)
    private val writer = CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
        for (value in pending) persist(value)
    }
    private fun update(value: LearningData) { data = value; pending.trySend(value) }
    private fun persist(value: LearningData) {
        val root = JSONObject()
        root.put("history", JSONArray(value.history.map(::wordJson)))
        root.put("bookmarks", JSONArray(value.bookmarks.map(::wordJson)))
        val study = JSONObject()
        value.study.forEach { (key, stat) -> study.put(key, JSONObject().put("right", stat.right).put("wrong", stat.wrong).put("last", stat.last)) }
        root.put("study", study)
        root.put("settings", JSONObject()
            .put("darkMode", value.settings.darkMode)
            .put("historyEnabled", value.settings.historyEnabled)
            .put("historyLimit", value.settings.historyLimit)
            .put("quizLength", value.settings.quizLength)
            .put("randomPool", value.settings.randomPool)
            .put("collapsePronunciation", value.settings.collapsePronunciation)
            .put("collapseEtymology", value.settings.collapseEtymology)
            .put("collapseOtherSections", value.settings.collapseOtherSections)
            .put("collapseDetails", value.settings.collapseDetails)
            .put("allowImages", value.settings.allowImages)
            .put("allowAudio", value.settings.allowAudio)
            .put("mediaCacheMb", value.settings.mediaCacheMb))
        prefs.edit { putString("state", root.toString()) }
    }

    private fun load(): LearningData = runCatching {
        val raw = prefs.getString("state", null) ?: return@runCatching LearningData()
        val root = JSONObject(raw)
        val settings = root.optJSONObject("settings") ?: JSONObject()
        LearningData(
            history = words(root.optJSONArray("history")).take(100_000),
            bookmarks = words(root.optJSONArray("bookmarks")).take(1000),
            study = study(root.optJSONObject("study")),
            settings = AppSettings(
                darkMode = settings.optString("darkMode", "system").takeIf { it in setOf("system", "light", "dark") } ?: "system",
                collapsePronunciation = settings.optBoolean("collapsePronunciation", true),
                collapseEtymology = settings.optBoolean("collapseEtymology", true),
                collapseOtherSections = settings.optBoolean("collapseOtherSections", true),
                collapseDetails = settings.optBoolean("collapseDetails", true),
                allowImages = settings.optBoolean("allowImages", false),
                allowAudio = settings.optBoolean("allowAudio", false),
                mediaCacheMb = settings.optInt("mediaCacheMb", 100).coerceIn(0,4096),
                historyEnabled = settings.optBoolean("historyEnabled", true),
                historyLimit = settings.optInt("historyLimit", 100).coerceIn(1, 100_000),
                quizLength = settings.optInt("quizLength", 10).coerceIn(3, 50),
                randomPool = settings.optString("randomPool", "all").takeIf { it in setOf("all", "history", "bookmarks") } ?: "all",
            ),
        )
    }.getOrDefault(LearningData())
    private fun wordJson(word: SavedWord) = JSONObject()
        .put("key", word.key).put("title", word.title).put("language", word.language)
        .put("kind", word.kind).put("clue", word.clue).put("savedAt", word.savedAt)
        .put("lastViewed", word.lastViewed).put("views", word.views)
        .put("dictionary",word.dictionary).put("recordKey",word.recordKey).put("contextDictionary",word.contextDictionary).put("edition",word.edition)

    private fun words(array: JSONArray?): List<SavedWord> = if (array == null) emptyList() else
        (0 until array.length()).mapNotNull { index -> runCatching {
            val value = array.getJSONObject(index)
            SavedWord(
                key = value.getString("key"), title = value.getString("title"),
                language = if (value.isNull("language") || !value.has("language")) null else value.optString("language").takeIf { it.isNotBlank() },
                kind = value.optString("kind", "language"), clue = value.optString("clue"),
                savedAt = value.optLong("savedAt"), lastViewed = value.optLong("lastViewed"),
                views = value.optInt("views", 1),
                dictionary = value.optString("dictionary").takeIf { it.isNotEmpty() },
                recordKey = value.optString("recordKey").takeIf { it.isNotEmpty() },
                contextDictionary = value.optString("contextDictionary").takeIf { it.isNotEmpty() },
                edition = value.optString("edition").takeIf { it.isNotEmpty() },
            )
        }.getOrNull() }

    private fun study(value: JSONObject?): Map<String, StudyStat> = if (value == null) emptyMap() else
        value.keys().asSequence().mapNotNull { key -> runCatching {
            val stat = value.getJSONObject(key)
            key to StudyStat(stat.optInt("right").coerceAtLeast(0), stat.optInt("wrong").coerceAtLeast(0), stat.optLong("last").coerceAtLeast(0))
        }.getOrNull() }.toMap()
}

internal fun LearningData.recordEntry(entry: Entry, now: Long): LearningData {
    val word = entry.saved(now)
    // Refresh only a resolved stored identity; legacy rows without provenance are not guessed.
    fun refresh(words: List<SavedWord>) = words.map { old ->
        if (word.dictionary != null && word.recordKey != null && old.key == word.key &&
            old.dictionary == word.dictionary && old.recordKey == word.recordKey &&
            old.contextDictionary == word.contextDictionary && old.edition.orEmpty() == word.edition.orEmpty())
            old.copy(clue = word.clue) else old
    }
    val refreshedBookmarks = refresh(bookmarks)
    if (!settings.historyEnabled) return copy(bookmarks = refreshedBookmarks, history = refresh(history))
    val previous = history.firstOrNull { it.key == word.key }
    val merged = word.copy(views = (previous?.views ?: 0) + 1, lastViewed = now)
    val recorded = (listOf(merged) + history.filterNot { it.key == word.key })
        .take(settings.historyLimit.coerceIn(1, 100_000))
    return copy(history = recorded, bookmarks = refreshedBookmarks)
}

private fun Entry.saved(now: Long) = SavedWord(
    key = key, title = redirect?.source ?: origin?.title ?: title, language = origin?.language?.takeIf { it.isNotEmpty() } ?: language,
    kind = origin?.kind ?: kind, clue = clue(),
    lastViewed = now, views = 1,
    dictionary = origin?.dictionary, recordKey = origin?.recordKey, contextDictionary = origin?.contextDictionary, edition = edition.takeIf { it.isNotEmpty() },
)
