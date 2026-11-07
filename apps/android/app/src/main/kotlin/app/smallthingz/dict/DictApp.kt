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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.platform.LocalView
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.findViewTreeViewModelStoreOwner
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch

enum class AppScreen { Dictionary, Library, Saved, History, Learn, Settings }

/** Configuration-lifetime reader data only; no Activity, callback, scope or pending job. */
internal class ReaderSession : ViewModel() {
    private var library: LibraryStore? = null
    internal var selected by mutableStateOf<Entry?>(null)
    internal var anchorRequest by mutableStateOf<EntryAnchorRequest?>(null)
    internal var visits by mutableStateOf(EntryVisitState())
    internal var navigationState = EntryNavigationState()
    internal val readingStates = mutableMapOf<Long, EntryReadingState>()
    internal var controllerToken: Any? = null

    internal fun bind(next: LibraryStore) {
        if (library === next) return
        library = next
        selected = null
        anchorRequest = null
        visits = EntryVisitState()
        navigationState = EntryNavigationState()
        readingStates.clear()
        controllerToken = null
    }
}

@Composable
fun DictApp(library: LibraryStore, learning: LearningStore,
    importNavigationRequest: Long = 0L, onImportNavigationHandled: (Long) -> Unit = {},
    onImport: () -> Unit) {
    var screen by rememberSaveable { mutableStateOf(AppScreen.Dictionary) }
    var importLibraryVisit by rememberSaveable { mutableStateOf(false) }
    var query by rememberSaveable { mutableStateOf("") }
    var dockHidden by remember { mutableStateOf(false) }
    var searching by rememberSaveable { mutableStateOf(false) }
    val owner = checkNotNull(LocalView.current.findViewTreeViewModelStoreOwner())
    val session = remember(owner, library) {
        ViewModelProvider(owner)[ReaderSession::class.java].also { it.bind(library) }
    }
    var selected by session::selected
    var anchorRequest by session::anchorRequest
    var loading by remember { mutableStateOf(false) }
    var visits by session::visits
    val readingStates = session.readingStates
    val navigationState = session.navigationState
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    val uri = androidx.compose.ui.platform.LocalUriHandler.current
    fun showEntry(hit: WordHit, entry: Entry, target: EntryLink, returning: Boolean) {
        selected = entry
        val fragment = if (returning) "" else if (target.hasFragment) target.fragment
            else entry.redirect?.takeIf { it.followed }?.fragment.orEmpty()
        anchorRequest = fragment.takeIf { it.isNotEmpty() }?.let { EntryAnchorRequest(entry.key, "#$it") }
        library.rememberWord(hit); learning.record(entry)
        query = ""; searching = false; screen = AppScreen.Dictionary; importLibraryVisit = false; keyboard?.hide()
    }
    val currentLibrary by rememberUpdatedState(library)
    val currentShowEntry by rememberUpdatedState<(WordHit, Entry, EntryLink, Boolean) -> Unit> { hit, entry, target, returning ->
        showEntry(hit, entry, target, returning)
    }
    // Committed visits belong to the Activity session; each composition owns a new
    // controller and callbacks. A detached controller cannot publish into its successor.
    val controllerToken = remember(scope, session, navigationState) {
        Any().also {
            session.controllerToken = it
            session.visits = navigationState.snapshot() // Pending work belonged to the old composition.
        }
    }
    val navigation = remember(scope, session, navigationState) {
        EntryNavigation(
            scope = scope,
            read = { currentLibrary.read(it) },
            link = { target, entry -> currentLibrary.link(target, entry) },
            saved = { currentLibrary.savedWord(it) },
            random = { currentLibrary.random() },
            initial = { currentLibrary.lastWord() ?: currentLibrary.search("", 1).firstOrNull() },
            commit = { hit, entry, target ->
                if (session.controllerToken === controllerToken) currentShowEntry(hit, entry, target, false)
            },
            restore = { hit, entry ->
                if (session.controllerToken === controllerToken) currentShowEntry(hit, entry, EntryLink(""), true)
            },
            visitsChanged = { state ->
                if (session.controllerToken === controllerToken) {
                    readingStates.keys.retainAll(state.retainedIds)
                    visits = state
                }
            },
            loading = { if (session.controllerToken === controllerToken) loading = it },
            error = { if (session.controllerToken === controllerToken) snackbar.showSnackbar(it) },
            installed = { id -> currentLibrary.dictionaries.any { it.id == id } },
            state = navigationState,
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
    LaunchedEffect(library, library.revision) {
        // Revision zero is the initial database load, not a completed empty library.
        if (library.revision == 0) return@LaunchedEffect
        navigation.libraryChanged()
        if (selected?.isInstalled { id -> library.dictionaries.any { it.id == id } } == false) {
            selected = null; anchorRequest = null
        }
        if (library.dictionaries.isEmpty()) {
            navigation.cancel()
            selected = null; anchorRequest = null
            // Keep the empty Library presentation at the Dictionary root.
        } else if (selected == null && screen == AppScreen.Dictionary && !searching) navigation.openInitialIfIdle()
    }
    fun openWord(word: SavedWord) { navigation.openSaved(word) }
    fun randomWord() { navigation.openRandom() }
    fun returnTo(destination: AppScreen) {
        navigation.interrupt {
            searching = false; query = ""
            screen = destination
            importLibraryVisit = false
            keyboard?.hide()
        }
        // A recreated search/screen retains its intent, but the decoded entry is not saveable.
        if (screen == AppScreen.Dictionary && !searching && selected == null &&
            library.revision > 0 && library.dictionaries.isNotEmpty()) navigation.openInitial()
    }
    LaunchedEffect(importNavigationRequest) {
        if (importNavigationRequest != 0L) navigation.interrupt {
            searching = false; query = ""
            screen = AppScreen.Library
            // An automatic refresh queued behind the import would erase its error.
            importLibraryVisit = true
            keyboard?.hide()
            onImportNavigationHandled(importNavigationRequest)
        }
    }
    androidx.activity.compose.BackHandler(searching || screen != AppScreen.Dictionary || visits.canGoBack) {
        if (searching || screen != AppScreen.Dictionary)
            returnTo(if (screen == AppScreen.Library) AppScreen.Settings else AppScreen.Dictionary)
        else navigation.goBack()
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
                                DockButton(screenIcon(target), target.name, screen == target || (target == AppScreen.Settings && screen == AppScreen.Library),
                                    selectedActionLabel = "Search".takeIf { target == AppScreen.Dictionary && library.dictionaries.isNotEmpty() }) {
                                    navigation.interrupt {
                                        if (target == AppScreen.Dictionary) searching = library.dictionaries.isNotEmpty()
                                        screen = target
                                        importLibraryVisit = false
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
                    AppScreen.Library -> LibraryScreen(library,
                        autoRefresh = !importLibraryVisit && importNavigationRequest == 0L, onImport = onImport)
                    AppScreen.Dictionary -> {
                        if (searching) {
                            SearchResults(query, library.revision, { library.search(it) }, ::open)
                        } else selected?.let { entry ->
                            CompositionLocalProvider(LocalUriHandler provides readerUri) {
                                EntryView(entry, learning.isBookmarked(entry), { learning.toggleBookmark(entry) }, readingState = visits.currentId?.takeIf { visits.entryKey == entry.key }?.let {
                                    readingStates.getOrPut(it) { EntryReadingState() }
                                }, settings = learning.data.settings, onScrollDirection = { dockHidden = it }, anchorRequest = anchorRequest, onAnchorConsumed = { if (anchorRequest === it) anchorRequest = null }, onNavigate = { navigation.cancel() }, onLink = { target ->
                                    dispatchEntryLink(entry, target, readerUri::openUri,
                                        { navigation.openLink(it, entry) },
                                        { scope.launch { snackbar.showSnackbar("The source edition for this link is unavailable.") } })
                                })
                            }
                        } ?: LibraryScreen(library, autoRefresh = importNavigationRequest == 0L, onImport = onImport)
                    }
                    AppScreen.Saved -> SavedScreen(learning, false, ::openWord)
                    AppScreen.History -> SavedScreen(learning, true, ::openWord)
                    AppScreen.Learn -> {
                        LearnResults(library.revision, learning.data.settings.randomPool, {
                            val hits=LinkedHashMap<String,WordHit>()
                            repeat(64){library.random()?.let{hits[it.key]=it}}
                            hits.values.mapNotNull { try{library.read(it)}catch(e:kotlinx.coroutines.CancellationException){throw e}catch(_:Exception){null} }
                        }) { study, pending, failed, retry ->
                            LearnScreen(learning, study, ::openWord, ::randomWord, pending, failed, retry,
                                library.revision, { word ->
                                    activeStudyClue(word, listOfNotNull(selected) + study, library::savedWord, library::read,
                                        { id -> library.dictionaries.any { it.id == id } })
                                })
                        }
                    }
                    AppScreen.Settings -> SettingsScreen(learning) { navigation.interrupt {
                        importLibraryVisit = false; screen = AppScreen.Library
                    } }
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
private sealed interface SearchResult {
    data object Loading : SearchResult
    data class Matches(val hits: List<WordHit>) : SearchResult
    data object Failed : SearchResult
}

@Composable
internal fun SearchResults(query: String, revision: Int, search: suspend (String) -> List<WordHit>, open: (WordHit) -> Unit) {
    // Each query/library version owns its visible state, including the first pending frame.
    key(query, revision) {
        var retry by remember { mutableIntStateOf(0) }
        key(retry) {
            val currentSearch by rememberUpdatedState(search)
            val result by produceState<SearchResult>(SearchResult.Loading) {
                try {
                    val hits = currentSearch(query)
                    currentCoroutineContext().ensureActive()
                    value = SearchResult.Matches(hits)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    currentCoroutineContext().ensureActive()
                    value = SearchResult.Failed
                }
            }
            when (val state = result) {
                SearchResult.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        CircularProgressIndicator(Modifier.size(24.dp))
                        Text("Searching…")
                    }
                }
                is SearchResult.Matches -> WordMatches(state.hits, open)
                SearchResult.Failed -> Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Unable to search dictionaries. Try again.")
                        TextButton(onClick = { retry++ }) { Text("Retry search") }
                    }
                }
            }
        }
    }
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
            modifier = Modifier.weight(1f).focusRequester(focus).semantics { contentDescription = "Find a word" },
            decorationBox = { field -> Box { if (query.isEmpty()) Text("Find a word…", color = MaterialTheme.colorScheme.onSurfaceVariant); field() } },
        )
        if (query.isNotEmpty()) IconButton(onClick = { onQuery(""); focus.requestFocus() }) { Icon(Icons.Filled.Close, "Clear search") }
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
