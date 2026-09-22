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
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.ui.focus.focusRequester
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

enum class AppScreen { Dictionary, Saved, Learn, Settings }

@Composable
fun DictApp(document: DocumentState, learning: LearningStore, onOpen: () -> Unit, onReload: () -> Unit) {
    var screen by rememberSaveable { mutableStateOf(AppScreen.Dictionary) }
    var query by rememberSaveable { mutableStateOf("") }
    var searching by rememberSaveable { mutableStateOf(false) }
    var selectedKey by rememberSaveable { mutableStateOf<String?>(null) }
    var menu by remember { mutableStateOf(false) }
    val loaded = document as? DocumentState.Loaded
    val entries = loaded?.results?.entries.orEmpty()
    val selected = loaded?.results?.byKey?.get(selectedKey) ?: entries.firstOrNull()
    LaunchedEffect(loaded) { if (loaded != null) { screen = AppScreen.Dictionary; query = ""; searching = false } }
    LaunchedEffect(selected?.key) { selected?.let(learning::record) }
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    fun select(key: String) { selectedKey = key; query = ""; searching = false; screen = AppScreen.Dictionary; keyboard?.hide() }
    fun openWord(word: SavedWord) {
        if (loaded?.results?.byKey?.containsKey(word.key) == true) select(word.key)
        else scope.launch { snackbar.showSnackbar("${word.title} is not in this dictionary.") }
    }
    fun randomWord() {
        val source = when (learning.data.settings.randomPool) {
            "history" -> learning.data.history.mapNotNull { loaded?.results?.byKey?.get(it.key) }
            "bookmarks" -> learning.data.bookmarks.mapNotNull { loaded?.results?.byKey?.get(it.key) }
            else -> entries
        }
        source.randomOrNull()?.let { select(it.key) }
    }
    androidx.activity.compose.BackHandler(searching || screen != AppScreen.Dictionary) {
        searching = false; query = ""; screen = AppScreen.Dictionary; keyboard?.hide()
    }
    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        bottomBar = {
            Surface(color = MaterialTheme.colorScheme.surfaceContainerLow) {
                Box(Modifier.navigationBarsPadding().imePadding()) {
                    androidx.compose.animation.Crossfade(targetState = searching, label = "dock") { search ->
                        if (search) SearchDock(query, { query = it }, { searching = false; query = ""; keyboard?.hide() })
                        else Row(Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                            AppScreen.entries.forEach { target ->
                                DockButton(screenIcon(target), target.name, screen == target) {
                                    if (target == AppScreen.Dictionary && screen == target && loaded != null) searching = true
                                    screen = target
                                }
                            }
                            Box {
                                DockButton(Icons.Filled.MoreHoriz, "More", false) { menu = true }
                                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                                    DropdownMenuItem(text = { Text("Open dictionary") }, leadingIcon = { Icon(Icons.Filled.FolderOpen, null) }, onClick = { menu = false; onOpen() })
                                    DropdownMenuItem(text = { Text("Random word") }, leadingIcon = { Icon(Icons.Filled.Casino, null) }, onClick = { menu = false; randomWord() })
                                }
                            }
                        }
                    }
                }
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            androidx.compose.animation.Crossfade(targetState = screen, animationSpec = androidx.compose.animation.core.tween(160), label = "page") { destination ->
            when (destination) {
                AppScreen.Dictionary -> when (document) {
                    DocumentState.Empty -> EmptyDocument(onOpen)
                    is DocumentState.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.size(24.dp)) }
                    is DocumentState.Failed -> Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(document.message); OutlinedButton(onClick = onReload) { Text("Retry") }; TextButton(onClick = onOpen) { Text("Open dictionary") }
                    }
                    is DocumentState.Loaded -> {
                        if (searching && query.isNotBlank()) {
                            val matches by produceState<List<Entry>>(emptyList(), entries, query) {
                                value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
                                    entries.asSequence().filter { it.title.contains(query, ignoreCase = true) }.take(80).toList()
                                }
                            }
                            EntryMatches(matches, ::select)
                        } else if (selected != null) EntryView(selected, learning.isBookmarked(selected), { learning.toggleBookmark(selected) }) { target ->
                            val title = target.substringBefore('#').replace('_', ' ')
                            val match = loaded?.results?.byTitle?.get(title)
                            if (match != null) select(match.key)
                            else scope.launch { snackbar.showSnackbar("$title is not in this dictionary.") }
                        }
                    }
                }
                AppScreen.Saved -> SavedScreen(learning, ::openWord)
                AppScreen.Learn -> LearnScreen(learning, entries, ::openWord, ::randomWord)
                AppScreen.Settings -> SettingsScreen(learning)
            }
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
private fun SearchDock(query: String, onQuery: (String) -> Unit, onClose: () -> Unit) {
    val focus = remember { androidx.compose.ui.focus.FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    Row(Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Close search") }
        androidx.compose.foundation.text.BasicTextField(
            value = query, onValueChange = onQuery, singleLine = true,
            textStyle = MaterialTheme.typography.titleMedium.copy(color = MaterialTheme.colorScheme.onSurface),
            cursorBrush = androidx.compose.ui.graphics.SolidColor(MaterialTheme.colorScheme.primary),
            modifier = Modifier.weight(1f).focusRequester(focus),
            decorationBox = { field -> Box { if (query.isEmpty()) Text("Find a word…", color = MaterialTheme.colorScheme.onSurfaceVariant); field() } },
        )
        if (query.isNotEmpty()) IconButton(onClick = { onQuery("") }) { Icon(Icons.Filled.Close, "Clear search") }
    }
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
            Button(onClick = onOpen) { Icon(Icons.Filled.FolderOpen, null); Spacer(Modifier.width(8.dp)); Text("Open dictionary") }
        }
    }
}
@Composable
private fun SavedScreen(learning: LearningStore, onOpen: (SavedWord) -> Unit) {
    var history by rememberSaveable { mutableStateOf(false) }
    val words = if (history) learning.data.history else learning.data.bookmarks
    Column(Modifier.fillMaxSize()) {
        Text("Saved", Modifier.padding(horizontal = 24.dp, vertical = 16.dp), style = MaterialTheme.typography.headlineMedium)
        Segments(listOf(false, true), history, { if (it) "History" else "Bookmarks" }, { history = it }, Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 8.dp))
        if (words.isEmpty()) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text(if (history) "No viewed words yet." else "Bookmark a word to keep it here.") }
        else LazyColumn(contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)) {
            items(words, key = { it.key }) { word ->
                ListItem(
                    headlineContent = { Text(word.title, style = MaterialTheme.typography.titleLarge) },
                    supportingContent = { Column { Text(word.language ?: word.kind.replace('_', ' ')); Text(word.clue, maxLines = 2) } },
                    trailingContent = { IconButton(onClick = { if (history) learning.removeHistory(word.key) else learning.removeBookmark(word.key) }) { Icon(Icons.Filled.Close, "Remove ${word.title}", Modifier.size(18.dp)) } },
                    modifier = Modifier.clickable { onOpen(word) },
                )
            }
        }
    }
}
