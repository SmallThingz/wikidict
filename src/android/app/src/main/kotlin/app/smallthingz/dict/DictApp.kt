package app.smallthingz.dict

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bookmarks
import androidx.compose.material.icons.filled.Casino
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.School
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

enum class AppScreen { Dictionary, Saved, Learn, Settings }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DictApp(document: DocumentState, learning: LearningStore, onOpen: () -> Unit, onReload: () -> Unit) {
    var screen by rememberSaveable { mutableStateOf(AppScreen.Dictionary) }
    var query by rememberSaveable { mutableStateOf("") }
    var selectedKey by rememberSaveable { mutableStateOf<String?>(null) }
    val loaded = document as? DocumentState.Loaded
    val entries = loaded?.results?.entries.orEmpty()
    LaunchedEffect(entries) {
        if (selectedKey == null || entries.none { it.key == selectedKey }) selectedKey = entries.firstOrNull()?.key
    }
    val selected = entries.firstOrNull { it.key == selectedKey }
    LaunchedEffect(selected?.key) { selected?.let(learning::record) }
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    fun openWord(word: SavedWord) {
        val match = entries.firstOrNull { it.key == word.key }
        if (match != null) { selectedKey = match.key; query = ""; screen = AppScreen.Dictionary }
        else scope.launch { snackbar.showSnackbar("${word.title} is not in the currently opened dictionary.") }
    }
    fun randomWord() {
        val candidates = learning.pool(entries).filter { word -> entries.any { it.key == word.key } }
        if (candidates.isEmpty()) scope.launch { snackbar.showSnackbar("Open an export or save some words first.") }
        else openWord(candidates.random())
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = { TopAppBar(
            title = { Column { Text("Dict", fontWeight = FontWeight.Bold); Text(loaded?.name ?: "Offline Wiktionary", style = MaterialTheme.typography.labelSmall) } },
            actions = {
                IconButton(onClick = ::randomWord) { Icon(Icons.Filled.Casino, "Random word") }
                IconButton(onClick = onOpen) { Icon(Icons.Filled.FolderOpen, "Open dictionary") }
            },
        ) },
        bottomBar = { NavigationBar {
            AppScreen.entries.forEach { target ->
                NavigationBarItem(selected = screen == target, onClick = { screen = target }, icon = { Icon(screenIcon(target), target.name) }, label = { Text(target.name) })
            }
        } },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when (screen) {
                AppScreen.Dictionary -> DictionaryScreen(document, entries, selected, query, { query = it }, { selectedKey = it; query = "" }, learning, onOpen, onReload)
                AppScreen.Saved -> SavedScreen(learning, ::openWord)
                AppScreen.Learn -> LearnScreen(learning, entries, ::openWord, ::randomWord)
                AppScreen.Settings -> SettingsScreen(learning)
            }
        }
    }
}
private fun screenIcon(screen: AppScreen) = when (screen) {
    AppScreen.Dictionary -> Icons.Filled.Search
    AppScreen.Saved -> Icons.Filled.Bookmarks
    AppScreen.Learn -> Icons.Filled.School
    AppScreen.Settings -> Icons.Filled.Settings
}

@Composable
private fun DictionaryScreen(
    document: DocumentState, entries: List<Entry>, selected: Entry?, query: String,
    onQuery: (String) -> Unit, onSelect: (String) -> Unit, learning: LearningStore,
    onOpen: () -> Unit, onReload: () -> Unit,
) {
    when (document) {
        DocumentState.Empty -> EmptyDocument(onOpen)
        is DocumentState.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        is DocumentState.Failed -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) { Text(document.message); Button(onClick = onReload) { Text("Retry") }; OutlinedButton(onClick = onOpen) { Text("Open another export") } } }
        is DocumentState.Loaded -> Column(Modifier.fillMaxSize()) {
            SearchBar(query, onQuery)
            val matches = remember(entries, query) { if (query.isBlank()) emptyList() else entries.filter { it.title.contains(query, ignoreCase = true) }.take(80) }
            if (query.isNotBlank()) EntryMatches(matches, onSelect)
            else if (selected != null) EntryView(selected, learning.isBookmarked(selected)) { learning.toggleBookmark(selected) }
            else EmptyDocument(onOpen)
        }
    }
}
@Composable
private fun SearchBar(query: String, onQuery: (String) -> Unit) {
    OutlinedTextField(
        value = query, onValueChange = onQuery, singleLine = true,
        leadingIcon = { Icon(Icons.Filled.Search, null) }, label = { Text("Find in this dictionary") },
        modifier = Modifier.fillMaxWidth().padding(16.dp),
    )
}

@Composable
private fun EntryMatches(entries: List<Entry>, onSelect: (String) -> Unit) {
    if (entries.isEmpty()) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("No matching words in this dictionary.") }
    else LazyColumn(contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp)) {
        items(entries, key = { it.key }) { entry ->
            ListItem(
                headlineContent = { Text(entry.title) },
                supportingContent = { Text(entry.language ?: entry.kind.replace('_', ' ')) },
                modifier = Modifier.clickable { onSelect(entry.key) },
            )
        }
    }
}

@Composable
private fun EmptyDocument(onOpen: () -> Unit) {
    Box(Modifier.fillMaxSize().padding(28.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Your dictionary, offline.", style = MaterialTheme.typography.headlineMedium)
            Text("Open a compiled Dict JSON package. Reading, bookmarks, history and games stay on this device.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            Button(onClick = onOpen) { Icon(Icons.Filled.FolderOpen, null); Spacer(Modifier.width(8.dp)); Text("Open dictionary") }
        }
    }
}
@Composable
private fun SavedScreen(learning: LearningStore, onOpen: (SavedWord) -> Unit) {
    var history by rememberSaveable { mutableStateOf(false) }
    val words = if (history) learning.data.history else learning.data.bookmarks
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.padding(16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(selected = !history, onClick = { history = false }, label = { Text("Bookmarks (${learning.data.bookmarks.size})") }, leadingIcon = { Icon(Icons.Filled.Bookmarks, null) })
            FilterChip(selected = history, onClick = { history = true }, label = { Text("History (${learning.data.history.size})") }, leadingIcon = { Icon(Icons.Filled.History, null) })
        }
        if (words.isEmpty()) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text(if (history) "No viewed words yet." else "Bookmark a word to keep it here.") }
        else LazyColumn(contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)) {
            items(words, key = { it.key }) { word ->
                ListItem(
                    headlineContent = { Text(word.title) },
                    supportingContent = { Column { Text(word.language ?: word.kind.replace('_', ' ')); Text(word.clue, maxLines = 2) } },
                    trailingContent = { TextButton(onClick = { if (history) learning.removeHistory(word.key) else learning.removeBookmark(word.key) }) { Text("Remove") } },
                    modifier = Modifier.clickable { onOpen(word) },
                )
                HorizontalDivider()
            }
        }
    }
}
@Composable
private fun SettingsScreen(learning: LearningStore) {
    val settings = learning.data.settings
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        item { Text("Settings", style = MaterialTheme.typography.headlineMedium) }
        item { SettingGroup("Appearance") { Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { listOf("system", "light", "dark").forEach { mode -> FilterChip(selected = settings.darkMode == mode, onClick = { learning.updateSettings { it.copy(darkMode = mode) } }, label = { Text(mode.replaceFirstChar(Char::uppercase)) }) } } } }
        item { SettingGroup("History") {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) { Text("Remember viewed words"); Switch(checked = settings.historyEnabled, onCheckedChange = { enabled -> learning.updateSettings { it.copy(historyEnabled = enabled) } }) }
            ChoiceRow("Keep", settings.historyLimit, listOf(25, 100, 250, 500)) { value -> learning.updateSettings { it.copy(historyLimit = value) } }
        } }
        item { SettingGroup("Learning") {
            ChoiceRow("Quiz questions", settings.quizLength, listOf(5, 10, 20, 50)) { value -> learning.updateSettings { it.copy(quizLength = value) } }
            Text("Random word source", style = MaterialTheme.typography.labelMedium)
            Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) { listOf("all", "history", "bookmarks").forEach { source -> FilterChip(selected = settings.randomPool == source, onClick = { learning.updateSettings { it.copy(randomPool = source) } }, label = { Text(source.replaceFirstChar(Char::uppercase)) }) } }
        } }
        item { SettingGroup("Data") { Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { OutlinedButton(onClick = learning::clearStudy) { Text("Reset scores") }; OutlinedButton(onClick = learning::clearHistory) { Text("Clear history") } } } }
    }
}
@Composable
private fun SettingGroup(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        content()
        HorizontalDivider()
    }
}

@Composable
private fun ChoiceRow(label: String, selected: Int, values: List<Int>, onSelect: (Int) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(label, style = MaterialTheme.typography.labelMedium)
        Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
            values.forEach { value -> FilterChip(selected = selected == value, onClick = { onSelect(value) }, label = { Text(value.toString()) }) }
        }
    }
}
