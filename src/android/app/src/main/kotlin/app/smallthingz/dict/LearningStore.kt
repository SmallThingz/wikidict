package app.smallthingz.dict

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.edit
import org.json.JSONArray
import org.json.JSONObject

data class SavedWord(
    val key: String, val title: String, val language: String?, val kind: String, val clue: String,
    val savedAt: Long = 0, val lastViewed: Long = 0, val views: Int = 1,
)
data class StudyStat(val right: Int = 0, val wrong: Int = 0, val last: Long = 0)
data class AppSettings(
    val darkMode: String = "system",
    val historyEnabled: Boolean = true,
    val historyLimit: Int = 100,
    val quizLength: Int = 10,
    val randomPool: String = "all",
)
data class LearningData(
    val history: List<SavedWord> = emptyList(),
    val bookmarks: List<SavedWord> = emptyList(),
    val study: Map<String, StudyStat> = emptyMap(),
    val settings: AppSettings = AppSettings(),
)
class LearningStore(context: Context) {
    private val prefs = context.getSharedPreferences("dict.learning.v1", Context.MODE_PRIVATE)
    var data by mutableStateOf(load())
        private set

    fun record(entry: Entry) {
        if (!data.settings.historyEnabled) return
        val now = System.currentTimeMillis()
        val word = entry.saved(now)
        val previous = data.history.firstOrNull { it.key == word.key }
        val merged = word.copy(views = (previous?.views ?: 0) + 1, lastViewed = now)
        val history = (listOf(merged) + data.history.filterNot { it.key == word.key })
            .take(data.settings.historyLimit.coerceIn(1, 500))
        update(data.copy(history = history))
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
            historyLimit = transformed.historyLimit.coerceIn(1, 500),
            quizLength = transformed.quizLength.coerceIn(3, 50),
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

    private fun update(value: LearningData) { data = value; persist(value) }
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
            .put("randomPool", value.settings.randomPool))
        prefs.edit { putString("state", root.toString()) }
    }

    private fun load(): LearningData = runCatching {
        val raw = prefs.getString("state", null) ?: return@runCatching LearningData()
        val root = JSONObject(raw)
        val settings = root.optJSONObject("settings") ?: JSONObject()
        LearningData(
            history = words(root.optJSONArray("history")).take(500),
            bookmarks = words(root.optJSONArray("bookmarks")).take(1000),
            study = study(root.optJSONObject("study")),
            settings = AppSettings(
                darkMode = settings.optString("darkMode", "system").takeIf { it in setOf("system", "light", "dark") } ?: "system",
                historyEnabled = settings.optBoolean("historyEnabled", true),
                historyLimit = settings.optInt("historyLimit", 100).coerceIn(1, 500),
                quizLength = settings.optInt("quizLength", 10).coerceIn(3, 50),
                randomPool = settings.optString("randomPool", "all").takeIf { it in setOf("all", "history", "bookmarks") } ?: "all",
            ),
        )
    }.getOrDefault(LearningData())
    private fun wordJson(word: SavedWord) = JSONObject()
        .put("key", word.key).put("title", word.title).put("language", word.language)
        .put("kind", word.kind).put("clue", word.clue).put("savedAt", word.savedAt)
        .put("lastViewed", word.lastViewed).put("views", word.views)

    private fun words(array: JSONArray?): List<SavedWord> = if (array == null) emptyList() else
        (0 until array.length()).mapNotNull { index -> runCatching {
            val value = array.getJSONObject(index)
            SavedWord(
                key = value.getString("key"), title = value.getString("title"),
                language = if (value.isNull("language") || !value.has("language")) null else value.optString("language").takeIf { it.isNotBlank() },
                kind = value.optString("kind", "language"), clue = value.optString("clue"),
                savedAt = value.optLong("savedAt"), lastViewed = value.optLong("lastViewed"),
                views = value.optInt("views", 1),
            )
        }.getOrNull() }

    private fun study(value: JSONObject?): Map<String, StudyStat> = if (value == null) emptyMap() else
        value.keys().asSequence().mapNotNull { key -> runCatching {
            val stat = value.getJSONObject(key)
            key to StudyStat(stat.optInt("right").coerceAtLeast(0), stat.optInt("wrong").coerceAtLeast(0), stat.optLong("last").coerceAtLeast(0))
        }.getOrNull() }.toMap()
}

private fun Entry.saved(now: Long) = SavedWord(
    key = key, title = title, language = language, kind = kind, clue = clue(),
    lastViewed = now, views = 1,
)
