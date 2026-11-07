package app.smallthingz.dict

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Casino
import androidx.compose.material.icons.filled.Extension
import androidx.compose.material.icons.filled.Style
import androidx.compose.material.icons.filled.Quiz
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

private enum class Game { Quiz, Cards, Scramble }

@Composable
fun LearnScreen(learning: LearningStore, entries: List<Entry>, onOpen: (SavedWord) -> Unit, onRandom: () -> Unit,
    sampleLoading: Boolean = false, sampleFailed: Boolean = false, onRetry: () -> Unit = {},
    libraryRevision: Int = 0, loadStudyClue: suspend (SavedWord) -> String? = { null }) {
    val data = learning.data
    val pool = remember(entries, data.settings.randomPool, data.bookmarks, data.history) { learning.pool(entries) }
    LearnPanel(pool, data.settings.quizLength, learning::answer, onOpen, onRandom, sampleLoading, sampleFailed, onRetry,
        libraryRevision, loadStudyClue)
}

@Composable
internal fun LearnPanel(pool: List<SavedWord>, target: Int, onAnswer: (String, Boolean) -> Unit,
    onOpen: (SavedWord) -> Unit, onRandom: () -> Unit, sampleLoading: Boolean = false,
    sampleFailed: Boolean = false, onRetry: () -> Unit = {}, libraryRevision: Int = 0,
    loadStudyClue: suspend (SavedWord) -> String? = { null }) {
    var game by rememberSaveable { mutableStateOf(Game.Quiz) }
    // This bounded screen has one game. Keep its session composed when scrolled away.
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(18.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Learn", style = MaterialTheme.typography.headlineMedium)
                Text(if (pool.isEmpty() && sampleLoading) "Loading words…" else if (pool.isEmpty() && sampleFailed) "Words unavailable" else "${pool.size} ${if (pool.size == 1) "word" else "words"} to explore", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            IconButton(onClick = onRandom) { Icon(Icons.Filled.Casino, "Random word") }
        }
        if (sampleLoading) Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(Modifier.size(20.dp))
            Text("Loading dictionary words…")
        }
        if (sampleFailed) Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Unable to load dictionary words. Try again.")
            TextButton(onClick = onRetry) { Text("Retry words") }
        }
        Segments(Game.entries, game, { it.name }, { game = it }, Modifier.fillMaxWidth())
        when (game) {
            Game.Quiz -> QuizGame(pool, target, onAnswer, !sampleLoading && !sampleFailed)
            Game.Cards -> Flashcards(pool, onOpen, onAnswer, !sampleLoading && !sampleFailed, libraryRevision, loadStudyClue)
            Game.Scramble -> ScrambleGame(pool, onAnswer, !sampleLoading && !sampleFailed)
        }
    }
}
@Composable
internal fun QuizGame(pool: List<SavedWord>, target: Int, onAnswer: (String, Boolean) -> Unit, showEmpty: Boolean = true) {
    val hasChoices = remember(pool) { pool.distinctBy { it.title }.size >= 2 }
    var question by remember(pool) { mutableStateOf(pool.randomOrNull()) }
    var answerKey by remember(question) { mutableStateOf<String?>(null) }
    var right by remember { mutableIntStateOf(0) }
    var total by remember { mutableIntStateOf(0) }
    val choices = remember(question, pool) {
        val q = question ?: return@remember emptyList()
        (listOf(q) + pool.filterNot { it.title == q.title }.distinctBy { it.title }.shuffled().take(3)).shuffled()
    }
    Box(Modifier.fillMaxWidth()) { Column(Modifier.padding(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        if (hasChoices) Text("$right correct · $total of $target", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (!hasChoices) { if (showEmpty) Text("Open or bookmark at least two different words first.") }
        else if (total >= target) {
            Text("Round complete", style = MaterialTheme.typography.headlineSmall)
            Text("You got $right of $total correct.")
            Button(onClick = { right = 0; total = 0; answerKey = null; question = pool.randomOrNull() }) { Text("Start another round") }
        } else question?.let { word ->
            Text(word.clue, style = MaterialTheme.typography.titleMedium)
            choices.forEach { choice ->
                val answered = answerKey != null
                val correct = answered && choice.key == word.key
                val wrong = answerKey == choice.key && choice.key != word.key
                OutlinedButton(
                    onClick = { if (!answered) { val ok = choice.key == word.key; onAnswer(word.key, ok); if (ok) right++; total++; answerKey = choice.key } },
                    enabled = !answered, modifier = Modifier.fillMaxWidth(),
                    colors = if (correct) ButtonDefaults.outlinedButtonColors(containerColor = MaterialTheme.colorScheme.primaryContainer) else if (wrong) ButtonDefaults.outlinedButtonColors(containerColor = MaterialTheme.colorScheme.errorContainer) else ButtonDefaults.outlinedButtonColors(),
                ) { Text(choice.title) }
            }
            if (answerKey != null) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) { Text(if (answerKey == word.key) "Correct." else "Answer: ${word.title}", Modifier.weight(1f)); Button(onClick = { question = pool.filterNot { it.key == word.key }.randomOrNull() ?: word; answerKey = null }) { Text("Next") } }
        }
    } }
}
@Composable
internal fun Flashcards(pool: List<SavedWord>, onOpen: (SavedWord) -> Unit, onAnswer: (String, Boolean) -> Unit,
    showEmpty: Boolean = true, libraryRevision: Int = 0, loadStudyClue: suspend (SavedWord) -> String? = { null }) {
    var cardKey by rememberSaveable { mutableStateOf(pool.randomOrNull()?.key) }
    var revealedKey by rememberSaveable { mutableStateOf<String?>(null) }
    // Retain identity across Read without retaining stale saved-word metadata or a whole pool.
    val card = remember(pool, cardKey) { pool.firstOrNull { it.key == cardKey } ?: pool.randomOrNull() }
    val revealed = card != null && revealedKey == card.key
    SideEffect {
        if (card?.key != cardKey && (card != null || showEmpty)) {
            cardKey = card?.key
            revealedKey = null
        }
    }
    val currentLoader by rememberUpdatedState(loadStudyClue)
    val studyClue by key(card, libraryRevision) {
        produceState<String?>(null) {
            val word = card ?: return@produceState
            try {
                val loaded = currentLoader(word)
                currentCoroutineContext().ensureActive()
                value = loaded?.takeIf { it.isNotBlank() }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { currentCoroutineContext().ensureActive() }
        }
    }
    Box(Modifier.fillMaxWidth()) { Column(Modifier.padding(vertical = 12.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        if (card == null) { if (showEmpty) Text("Open or bookmark some words first.") } else card?.let { word ->
            FilledTonalButton(onClick = { cardKey = word.key; revealedKey = if (revealed) null else word.key }, modifier = Modifier.fillMaxWidth().heightIn(min = 150.dp), shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp)) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(word.title, style = MaterialTheme.typography.headlineMedium)
                    Text(if (revealed) studyClue ?: word.clue else "Recall the meaning, then tap to reveal.")
                }
            }
            if (revealed) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { onAnswer(word.key, false); cardKey = (pool.filterNot { it.key == word.key }.randomOrNull() ?: word).key; revealedKey = null }) { Text("Again") }
                Button(onClick = { onAnswer(word.key, true); cardKey = (pool.filterNot { it.key == word.key }.randomOrNull() ?: word).key; revealedKey = null }) { Text("Got it") }
                TextButton(onClick = { onOpen(word) }) { Text("Read") }
            }
        }
    } }
}

/** Reuse a matching decoded entry or read only the active card through normal saved-word resolution. */
internal suspend fun activeStudyClue(word: SavedWord, entries: List<Entry>,
    lookup: suspend (SavedWord) -> WordHit?, read: suspend (WordHit) -> Entry,
    installed: (String) -> Boolean): String? {
    currentCoroutineContext().ensureActive()
    val cached = entries.firstOrNull { entry ->
        val origin = entry.origin
        word.dictionary != null && origin != null && origin.key == word.key &&
            origin.dictionary == word.dictionary && origin.recordKey == word.recordKey &&
            origin.contextDictionary == word.contextDictionary && entry.edition == word.edition.orEmpty() &&
            entry.isInstalled(installed)
    }
    val entry = cached ?: run {
        val hit = lookup(word) ?: return null
        currentCoroutineContext().ensureActive()
        if (!hit.isInstalled(installed)) return null
        read(hit)
    }
    currentCoroutineContext().ensureActive()
    return entry.takeIf { it.isInstalled(installed) }?.studyClue()
}
@Composable
internal fun ScrambleGame(pool: List<SavedWord>, onAnswer: (String, Boolean) -> Unit, showEmpty: Boolean = true) {
    val playable = remember(pool) { playableScrambleWords(pool) }
    var word by remember(playable) { mutableStateOf(playable.randomOrNull()) }
    var guess by remember(word) { mutableStateOf("") }
    var status by remember(word) { mutableStateOf<Boolean?>(null) }
    val scrambled = remember(word) { word?.title?.let { scramble(it) }.orEmpty() }
    Box(Modifier.fillMaxWidth()) { Column(Modifier.padding(vertical = 12.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        if (word == null) { if (showEmpty) Text("Add a few longer words first.") } else word?.let { current ->
            Text(scrambled, style = MaterialTheme.typography.headlineLarge, letterSpacing = MaterialTheme.typography.headlineLarge.letterSpacing)
            Text(current.clue, color = MaterialTheme.colorScheme.onSurfaceVariant)
            OutlinedTextField(value = guess, onValueChange = { guess = it; status = null }, singleLine = true, label = { Text("Word") }, modifier = Modifier.fillMaxWidth())
            Button(onClick = {
                val correct = scrambleAnswerMatches(guess, current.title)
                onAnswer(current.key, correct); status = correct
            }, enabled = status == null && guess.isNotBlank()) { Text("Check") }
            status?.let { correct -> Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(if (correct) "Correct." else "Answer: ${current.title}", Modifier.weight(1f))
                TextButton(onClick = { word = playable.filterNot { it.key == current.key }.randomOrNull() ?: current; guess = ""; status = null }) { Text("Next") }
            } }
        }
    } }
}

private sealed interface LearnSample {
    data object Loading : LearnSample
    data class Ready(val entries: List<Entry>) : LearnSample
    data object Failed : LearnSample
}

@Composable
internal fun LearnResults(
    revision: Int,
    poolSource: String,
    sample: suspend () -> List<Entry>,
    content: @Composable (List<Entry>, Boolean, Boolean, () -> Unit) -> Unit,
) {
    // Saved/history pools need no optional dictionary sampling.
    val (state, retry) = if (poolSource == "bookmarks" || poolSource == "history") {
        LearnSample.Ready(emptyList()) to {}
    } else key(revision, poolSource) {
        var attempt by remember { mutableIntStateOf(0) }
        val currentSample by rememberUpdatedState(sample)
        val result by key(attempt) {
            produceState<LearnSample>(LearnSample.Loading) {
                try {
                    val entries = currentSample()
                    currentCoroutineContext().ensureActive()
                    value = LearnSample.Ready(entries)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    currentCoroutineContext().ensureActive()
                    value = LearnSample.Failed
                }
            }
        }
        result to { attempt++; Unit }
    }
    // Keep the game composition and round totals while its sampled pool changes.
    content((state as? LearnSample.Ready)?.entries.orEmpty(),
        state == LearnSample.Loading, state == LearnSample.Failed, retry)
}
