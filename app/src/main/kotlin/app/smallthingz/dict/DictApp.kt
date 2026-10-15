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
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler

enum class AppScreen { Dictionary, Library, Saved, History, Learn, Settings }

@Composable
fun DictApp(library: LibraryStore, learning: LearningStore, onImport: () -> Unit) {
    var screen by rememberSaveable { mutableStateOf(AppScreen.Dictionary) }
    var query by rememberSaveable { mutableStateOf("") }
    var dockHidden by remember { mutableStateOf(false) }
    var searching by rememberSaveable { mutableStateOf(false) }
    var selected by remember { mutableStateOf<Entry?>(null) }
    var anchorRequest by remember { mutableStateOf<EntryAnchorRequest?>(null) }
    var loading by remember { mutableStateOf(false) }
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    val uri = androidx.compose.ui.platform.LocalUriHandler.current
    val navigation = remember(library, learning, scope, snackbar, keyboard) {
        EntryNavigation(
            scope = scope,
            read = library::read,
            link = library::link,
            saved = library::savedWord,
            random = library::random,
            initial = { library.lastWord() ?: library.search("", 1).firstOrNull() },
            commit = { hit, entry, target ->
                selected = entry
                val fragment = if ('#' in target) target.substringAfter('#')
                    else entry.redirect?.takeIf { it.followed }?.fragment.orEmpty()
                anchorRequest = fragment.takeIf { it.isNotEmpty() }?.let { EntryAnchorRequest(entry.key, "#$it") }
                library.rememberWord(hit); learning.record(entry)
                query = ""; searching = false; screen = AppScreen.Dictionary; keyboard?.hide()
            },
            loading = { loading = it },
            error = { snackbar.showSnackbar(it) },
            installed = { id -> library.dictionaries.any { it.id == id } },
        )
    }
    DisposableEffect(navigation) { onDispose { navigation.cancel() } }
    val readerUri = remember(uri, navigation) {
        object : UriHandler {
            override fun openUri(uriString: String) {
                navigation.cancel()
                uri.openUri(uriString)
            }
        }
    }
    fun open(hit: WordHit) { navigation.open(hit) }
    LaunchedEffect(library.revision) {
        // Revision zero is the initial database load, not a completed empty library.
        if (library.revision == 0) return@LaunchedEffect
        navigation.libraryChanged()
        if (selected?.isInstalled { id -> library.dictionaries.any { it.id == id } } == false) {
            selected = null; anchorRequest = null
        }
        if (library.dictionaries.isEmpty()) {
            navigation.cancel()
            selected = null; anchorRequest = null
            if (screen == AppScreen.Dictionary && !searching) screen = AppScreen.Library
        } else if (selected == null && screen == AppScreen.Dictionary && !searching) navigation.openInitialIfIdle()
    }
    fun openWord(word: SavedWord) { navigation.openSaved(word) }
    fun randomWord() { navigation.openRandom() }
    fun returnTo(destination: AppScreen) {
        navigation.interrupt {
            searching = false; query = ""
            screen = if (destination == AppScreen.Dictionary && library.revision > 0 &&
                library.dictionaries.isEmpty()) AppScreen.Library else destination
            keyboard?.hide()
        }
        // A recreated search/screen retains its intent, but the decoded entry is not saveable.
        if (screen == AppScreen.Dictionary && !searching && selected == null &&
            library.revision > 0 && library.dictionaries.isNotEmpty()) navigation.openInitial()
    }
    androidx.activity.compose.BackHandler(searching || screen != AppScreen.Dictionary) {
        returnTo(if (screen == AppScreen.Library) AppScreen.Settings else AppScreen.Dictionary)
    }
    LaunchedEffect(screen, selected?.key, searching) { dockHidden = false }
    Scaffold(snackbarHost = { SnackbarHost(snackbar) }, bottomBar = {
        androidx.compose.animation.AnimatedVisibility(
            visible = !dockHidden || screen != AppScreen.Dictionary || searching,
            enter = androidx.compose.animation.slideInVertically { it } + androidx.compose.animation.fadeIn(),
            exit = androidx.compose.animation.slideOutVertically { it } + androidx.compose.animation.fadeOut(),
        ) {
        Surface(color = MaterialTheme.colorScheme.surfaceContainerLow) {
            Box(Modifier.navigationBarsPadding().imePadding()) {
                androidx.compose.animation.Crossfade(searching, label = "dock") { search ->
                    if (search) SearchDock(query, { value -> navigation.interrupt { query = value } }, { returnTo(AppScreen.Dictionary) })
                    else Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                        listOf(AppScreen.Saved, AppScreen.History, AppScreen.Dictionary, AppScreen.Learn, AppScreen.Settings).forEach { target ->
                            Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                                DockButton(screenIcon(target), target.name, screen == target || (target == AppScreen.Settings && screen == AppScreen.Library)) {
                                    navigation.interrupt {
                                        if (target == AppScreen.Dictionary) searching = library.dictionaries.isNotEmpty()
                                        screen = target
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        }
    }) { padding ->
        val reading = screen == AppScreen.Dictionary && !searching && selected != null
        // The dock overlays reading content; its animation never changes the viewport.
        val contentPadding = if (reading) PaddingValues(
            top = padding.calculateTopPadding(),
            bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding(),
        ) else padding
        Box(Modifier.fillMaxSize().padding(contentPadding)) {
            androidx.compose.animation.Crossfade(screen, animationSpec = androidx.compose.animation.core.tween(140), label = "page") { destination ->
                when(destination) {
                    AppScreen.Library -> LibraryScreen(library, onImport)
                    AppScreen.Dictionary -> {
                        if (searching) {
                            val matches by produceState<List<WordHit>>(emptyList(), library.revision, query) { value = library.search(query) }
                            WordMatches(matches, ::open)
                        } else selected?.let { entry ->
                            CompositionLocalProvider(LocalUriHandler provides readerUri) {
                                EntryView(entry, learning.isBookmarked(entry), { learning.toggleBookmark(entry) }, settings = learning.data.settings, onScrollDirection = { dockHidden = it }, anchorRequest = anchorRequest, onAnchorConsumed = { if (anchorRequest === it) anchorRequest = null }, onNavigate = { navigation.cancel() }, onLink = { target ->
                                    val bookSource = bookSourcesUrl(entry, target)
                                    if (target.startsWith("File:",true) || target.startsWith("Image:",true) || bookSource != null) {
                                        readerUri.openUri(bookSource ?: sourcePage(entry,target))
                                    } else navigation.openLink(target, entry)
                                })
                            }
                        } ?: LibraryScreen(library,onImport)
                    }
                    AppScreen.Saved -> SavedScreen(learning, false, ::openWord)
                    AppScreen.History -> SavedScreen(learning, true, ::openWord)
                    AppScreen.Learn -> {
                        val study by produceState<List<Entry>>(emptyList(),library.revision) {
                            val hits=LinkedHashMap<String,WordHit>()
                            repeat(64){library.random()?.let{hits[it.key]=it}}
                            value=hits.values.mapNotNull { try{library.read(it)}catch(e:kotlinx.coroutines.CancellationException){throw e}catch(_:Exception){null} }
                        }
                        LearnScreen(learning, study, ::openWord, ::randomWord)
                    }
                    AppScreen.Settings -> SettingsScreen(learning) { navigation.interrupt { screen = AppScreen.Library } }
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
    AppScreen.History -> Icons.Filled.History
    AppScreen.Learn -> Icons.Filled.School
    AppScreen.Settings -> Icons.Filled.Settings
}
@Composable
internal fun WordMatches(hits: List<WordHit>, open: (WordHit)->Unit) {
    if(hits.isEmpty()) Box(Modifier.fillMaxSize(),contentAlignment=Alignment.Center) { Text("No matching words",style=MaterialTheme.typography.bodyMedium) }
    else LazyColumn(contentPadding=PaddingValues(horizontal=12.dp)) { items(hits,key={it.key}) { hit ->
        ListItem(headlineContent={Text(hit.title,style=MaterialTheme.typography.titleLarge)},supportingContent={Column {Text(hit.language);Text(sourceLabel(hit.edition))}},modifier=Modifier.clickable {open(hit)})
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
private fun SavedScreen(learning: LearningStore, history: Boolean, onOpen: (SavedWord) -> Unit) {
    val words = if (history) learning.data.history else learning.data.bookmarks
    Column(Modifier.fillMaxSize()) {
        Text(if (history) "History" else "Saved", Modifier.padding(horizontal = 24.dp, vertical = 16.dp), style = MaterialTheme.typography.headlineMedium)
        if (words.isEmpty()) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text(if (history) "No viewed words yet." else "Bookmark a word to keep it here.") }
        else LazyColumn(contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)) {
            items(words, key = { it.key }) { word ->
                ListItem(
                    headlineContent = { Text(word.title, style = MaterialTheme.typography.titleLarge) },
                    supportingContent = { Column { Text(word.language ?: word.kind.replace('_', ' ')); Text(sourceLabel(word.edition.orEmpty())); Text(word.clue, maxLines = 2) } },
                    trailingContent = { IconButton(onClick = { if (history) learning.removeHistory(word.key) else learning.removeBookmark(word.key) }) { Icon(Icons.Filled.Close, "Remove ${word.title}", Modifier.size(18.dp)) } },
                    modifier = Modifier.clickable { onOpen(word) },
                )
            }
        }
    }
}
