package app.smallthingz.dict

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
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

private enum class Game { Quiz, Cards, Scramble }

@Composable
fun LearnScreen(learning: LearningStore, entries: List<Entry>, onOpen: (SavedWord) -> Unit, onRandom: () -> Unit) {
    val data = learning.data
    val pool = remember(entries, data.settings.randomPool, data.bookmarks, data.history) { learning.pool(entries) }
    var game by rememberSaveable { mutableStateOf(Game.Quiz) }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(18.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        item { Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Learn", style = MaterialTheme.typography.headlineMedium)
                Text("${pool.size} words to explore", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            IconButton(onClick = onRandom) { Icon(Icons.Filled.Casino, "Random word") }
        } }
        item { Segments(Game.entries, game, { it.name }, { game = it }, Modifier.fillMaxWidth()) }
        item { when (game) { Game.Quiz -> QuizGame(learning, pool); Game.Cards -> Flashcards(learning, pool, onOpen); Game.Scramble -> ScrambleGame(learning, pool) } }
    }
}
@Composable
private fun QuizGame(learning: LearningStore, pool: List<SavedWord>) {
    var question by remember(pool) { mutableStateOf(pool.randomOrNull()) }
    var answerKey by remember { mutableStateOf<String?>(null) }
    var right by remember { mutableIntStateOf(0) }
    var total by remember { mutableIntStateOf(0) }
    val target = learning.data.settings.quizLength
    val choices = remember(question, pool) {
        val q = question ?: return@remember emptyList()
        (listOf(q) + pool.filterNot { it.key == q.key }.shuffled().take(3)).shuffled()
    }
    Box(Modifier.fillMaxWidth()) { Column(Modifier.padding(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) { Text("Definition quiz", fontWeight = FontWeight.SemiBold); Text("$right / $total · $target") }
        if (pool.size < 2) Text("Open or bookmark a few words first.")
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
                    onClick = { if (!answered) { val ok = choice.key == word.key; learning.answer(word.key, ok); if (ok) right++; total++; answerKey = choice.key } },
                    enabled = !answered, modifier = Modifier.fillMaxWidth(),
                    colors = if (correct) ButtonDefaults.outlinedButtonColors(containerColor = MaterialTheme.colorScheme.primaryContainer) else if (wrong) ButtonDefaults.outlinedButtonColors(containerColor = MaterialTheme.colorScheme.errorContainer) else ButtonDefaults.outlinedButtonColors(),
                ) { Text(choice.title) }
            }
            if (answerKey != null) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) { Text(if (answerKey == word.key) "Correct." else "Answer: ${word.title}"); Button(onClick = { question = pool.filterNot { it.key == word.key }.randomOrNull() ?: word; answerKey = null }) { Text("Next") } }
        }
    } }
}
@Composable
private fun Flashcards(learning: LearningStore, pool: List<SavedWord>, onOpen: (SavedWord) -> Unit) {
    var card by remember(pool) { mutableStateOf(pool.randomOrNull()) }
    var revealed by remember { mutableStateOf(false) }
    Box(Modifier.fillMaxWidth()) { Column(Modifier.padding(vertical = 12.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("Flashcards", Modifier.fillMaxWidth(), fontWeight = FontWeight.SemiBold)
        if (card == null) Text("Open or bookmark some words first.") else card?.let { word ->
            FilledTonalButton(onClick = { revealed = !revealed }, modifier = Modifier.fillMaxWidth().heightIn(min = 150.dp)) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(word.title, style = MaterialTheme.typography.headlineMedium)
                    Text(if (revealed) word.clue else "Recall the meaning, then tap to reveal.")
                }
            }
            if (revealed) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { learning.answer(word.key, false); card = pool.filterNot { it.key == word.key }.randomOrNull() ?: word; revealed = false }) { Text("Again") }
                Button(onClick = { learning.answer(word.key, true); card = pool.filterNot { it.key == word.key }.randomOrNull() ?: word; revealed = false }) { Text("Got it") }
                TextButton(onClick = { onOpen(word) }) { Text("Read") }
            }
        }
    } }
}
@Composable
private fun ScrambleGame(learning: LearningStore, pool: List<SavedWord>) {
    val playable = remember(pool) { pool.filter { it.title.codePointCount(0, it.title.length) > 2 } }
    var word by remember(playable) { mutableStateOf(playable.randomOrNull()) }
    var guess by remember { mutableStateOf("") }
    var status by remember { mutableStateOf<Boolean?>(null) }
    val scrambled = remember(word) { word?.title?.let(::scramble).orEmpty() }
    Box(Modifier.fillMaxWidth()) { Column(Modifier.padding(vertical = 12.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("Unscramble", Modifier.fillMaxWidth(), fontWeight = FontWeight.SemiBold)
        if (word == null) Text("Add a few longer words first.") else word?.let { current ->
            Text(scrambled, style = MaterialTheme.typography.headlineLarge, letterSpacing = MaterialTheme.typography.headlineLarge.letterSpacing)
            Text(current.clue, color = MaterialTheme.colorScheme.onSurfaceVariant)
            OutlinedTextField(value = guess, onValueChange = { guess = it; status = null }, singleLine = true, label = { Text("Word") }, modifier = Modifier.fillMaxWidth())
            Button(onClick = {
                val correct = guess.trim().equals(current.title, ignoreCase = true)
                learning.answer(current.key, correct); status = correct
            }, enabled = status == null && guess.isNotBlank()) { Text("Check") }
            status?.let { correct -> Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text(if (correct) "Correct." else "Answer: ${current.title}")
                TextButton(onClick = { word = playable.filterNot { it.key == current.key }.randomOrNull() ?: current; guess = ""; status = null }) { Text("Next") }
            } }
        }
    } }
}

private fun scramble(value: String): String {
    val chars = value.codePoints().toArray().toMutableList()
    if (chars.size < 2) return value
    var shuffled = chars.shuffled()
    if (shuffled == chars) shuffled = chars.drop(1) + chars.first()
    return String(shuffled.toIntArray(), 0, shuffled.size)
}
