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

enum class AppScreen { Dictionary, Library, Saved, Learn, Settings }

@Composable
fun DictApp(library: LibraryStore, learning: LearningStore, onImport: () -> Unit) {
    var screen by rememberSaveable { mutableStateOf(AppScreen.Dictionary) }
    var query by rememberSaveable { mutableStateOf("") }
    var searching by rememberSaveable { mutableStateOf(false) }
    var selected by remember { mutableStateOf<Entry?>(null) }
    var selectedDictionary by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(false) }
    var selectionJob by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    val uri = androidx.compose.ui.platform.LocalUriHandler.current
    fun open(hit: WordHit) {
        selectionJob?.cancel()
        selectionJob = scope.launch {
            loading = true
            try { selected = library.read(hit); selectedDictionary = hit.dictionary; library.rememberWord(hit); selected?.let(learning::record); query = ""; searching = false; screen = AppScreen.Dictionary; keyboard?.hide() }
            catch(e: kotlinx.coroutines.CancellationException) { throw e }
            catch(e: Exception) { snackbar.showSnackbar(e.message ?: "Unable to read this word") }
            finally { loading = false }
        }
    }
    LaunchedEffect(library.revision) {
        if (library.dictionaries.none { it.id == selectedDictionary }) selected = null
        if (library.dictionaries.isEmpty()) { selected = null; screen = AppScreen.Library }
        else if (selected == null) (library.lastWord() ?: library.search("", 1).firstOrNull())?.let(::open)
    }
    fun openWord(word: SavedWord) { scope.launch { library.exact(word.title,word.language)?.let(::open) ?: snackbar.showSnackbar("Install the dictionary for ${word.title}.") } }
    fun randomWord() { scope.launch { library.random()?.let(::open) } }
    androidx.activity.compose.BackHandler(searching || screen != AppScreen.Dictionary) {
        searching = false; query = ""; screen = AppScreen.Dictionary; keyboard?.hide()
    }
    Scaffold(snackbarHost = { SnackbarHost(snackbar) }, bottomBar = {
        Surface(color = MaterialTheme.colorScheme.surfaceContainerLow) {
            Box(Modifier.navigationBarsPadding().imePadding()) {
                androidx.compose.animation.Crossfade(searching, label = "dock") { search ->
                    if (search) SearchDock(query, { query = it }, { searching = false; query = ""; keyboard?.hide() })
                    else Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                        AppScreen.entries.forEach { target -> DockButton(screenIcon(target), target.name, screen == target) {
                            if (target == AppScreen.Dictionary && screen == target && library.dictionaries.isNotEmpty()) searching = true
                            screen = target
                        } }
                    }
                }
            }
        }
    }) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            androidx.compose.animation.Crossfade(screen, animationSpec = androidx.compose.animation.core.tween(140), label = "page") { destination ->
                when(destination) {
                    AppScreen.Library -> LibraryScreen(library, onImport)
                    AppScreen.Dictionary -> {
                        if (searching) {
                            val matches by produceState<List<WordHit>>(emptyList(), library.revision, query) { value = library.search(query) }
                            WordMatches(matches, ::open)
                        } else selected?.let { entry -> EntryView(entry, learning.isBookmarked(entry), { learning.toggleBookmark(entry) }, settings = learning.data.settings, onLink = { target ->
                            if (target.startsWith("File:",true) || target.startsWith("Image:",true)) {
                                uri.openUri("https://en.wiktionary.org/wiki/" + java.net.URLEncoder.encode(target,"UTF-8").replace("+","%20"))
                            } else scope.launch { library.exact(target.substringBefore('#').replace('_',' '),entry.language)?.let(::open) ?: snackbar.showSnackbar("This word is not in your installed dictionaries.") }
                        }) } ?: LibraryScreen(library,onImport)
                    }
                    AppScreen.Saved -> SavedScreen(learning, ::openWord)
                    AppScreen.Learn -> {
                        val study by produceState<List<Entry>>(emptyList(),library.revision) {
                            val hits=LinkedHashMap<String,WordHit>()
                            repeat(64){library.random()?.let{hits[it.key]=it}}
                            value=hits.values.mapNotNull { try{library.read(it)}catch(e:kotlinx.coroutines.CancellationException){throw e}catch(_:Exception){null} }
                        }
                        LearnScreen(learning, study, ::openWord, ::randomWord)
                    }
                    AppScreen.Settings -> SettingsScreen(learning)
                }
            }
            if(loading) LinearProgressIndicator(Modifier.fillMaxWidth().align(Alignment.TopCenter))
        }
    }
}
private fun screenIcon(screen: AppScreen) = when(screen) {
    AppScreen.Dictionary -> Icons.Filled.Search
    AppScreen.Library -> Icons.Filled.FolderOpen
    AppScreen.Saved -> Icons.Filled.Bookmarks
    AppScreen.Learn -> Icons.Filled.School
    AppScreen.Settings -> Icons.Filled.Settings
}
@Composable
private fun WordMatches(hits: List<WordHit>, open: (WordHit)->Unit) {
    if(hits.isEmpty()) Box(Modifier.fillMaxSize(),contentAlignment=Alignment.Center) { Text("No matching words",style=MaterialTheme.typography.bodyMedium) }
    else LazyColumn(contentPadding=PaddingValues(horizontal=12.dp)) { items(hits,key={it.dictionary+"/"+it.title}) { hit ->
        ListItem(headlineContent={Text(hit.title,style=MaterialTheme.typography.titleLarge)},supportingContent={Text(hit.language)},modifier=Modifier.clickable {open(hit)})
    } }
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
