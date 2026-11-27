package app.smallthingz.dict

import android.app.Application
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal data class ReaderStores(val library: LibraryStore, val learning: LearningStore)

// Retain accepted URIs across recreation while the disk-backed stores open.
class ReaderStartup internal constructor(
    application: Application,
    private val savedState: SavedStateHandle,
    private val openStores: () -> ReaderStores
) : AndroidViewModel(application) {
    constructor(application: Application, savedState: SavedStateHandle) : this(
        application, savedState,
        { ReaderStores(LibraryStore.get(application), LearningStore.get(application)) }
    )

    internal var stores by mutableStateOf<ReaderStores?>(null); private set
    internal var failed by mutableStateOf(false); private set
    private var importNavigationSequence = savedState.get<Long>("importNavigationSequence") ?: 0L
    internal var importNavigationRequest by mutableStateOf(savedState.get<Long>("importNavigationRequest") ?: 0L); private set
    private var opening: Job? = null
    private val resolver = application.contentResolver

    init { retry() }

    internal fun retry() {
        if (stores != null || opening?.isActive == true) return
        failed = false
        opening = viewModelScope.launch {
            try {
                NativePackagedFont.prepare(getApplication<Application>())
                stores = withContext(Dispatchers.IO) { openStores() }
                drainImports()
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { failed = true }
        }
    }

    internal fun import(uri: Uri, showLibrary: Boolean = false) {
        if (showLibrary) {
            importNavigationSequence++
            savedState["importNavigationSequence"] = importNavigationSequence
            savedState["importNavigationRequest"] = importNavigationSequence
            importNavigationRequest = importNavigationSequence
        }
        val pending = savedState.get<ArrayList<Uri>>("pendingImports").orEmpty()
        savedState["pendingImports"] = ArrayList(pending + uri)
        drainImports()
    }

    internal fun importEdition(uri: Uri) {
        // Keep only the read grant the user selected; never release another import's grant.
        try { resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        catch (_: SecurityException) { /* Some providers offer only the current read grant. */ }
        importNavigationSequence++
        savedState["importNavigationSequence"] = importNavigationSequence
        savedState["importNavigationRequest"] = importNavigationSequence
        importNavigationRequest = importNavigationSequence
        val pending = savedState.get<ArrayList<Uri>>("pendingEditionImports").orEmpty()
        savedState["pendingEditionImports"] = ArrayList(pending + uri)
        drainImports()
    }

    internal fun consumeImportNavigation(request: Long) {
        if (request != importNavigationRequest) return
        savedState["importNavigationRequest"] = 0L
        importNavigationRequest = 0L
    }

    private fun drainImports() {
        val library = stores?.library ?: return
        while (true) {
            val pending = savedState.get<ArrayList<Uri>>("pendingImports").orEmpty()
            val uri = pending.firstOrNull() ?: break
            savedState["pendingImports"] = ArrayList(pending.drop(1))
            library.importFile(name = {
                resolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst()) c.getString(0).orEmpty() else ""
                }.orEmpty()
            }) { requireNotNull(resolver.openInputStream(uri)) { "Cannot open dictionary" } }
        }
        while (true) {
            val pending = savedState.get<ArrayList<Uri>>("pendingEditionImports").orEmpty()
            val uri = pending.firstOrNull() ?: return
            savedState["pendingEditionImports"] = ArrayList(pending.drop(1))
            library.importEdition(uri)
        }
    }
}

class MainActivity : ComponentActivity() {
    private lateinit var startup: ReaderStartup
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val picker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> uri?.let { startup.import(it) } }
        val editionPicker = registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri -> uri?.let { startup.importEdition(it) } }
        startup = ViewModelProvider(this)[ReaderStartup::class.java]
        setContent {
            val stores = startup.stores
            DictTheme(stores?.learning?.data?.settings?.darkMode ?: "system") {
                if (stores != null) {
                    DictApp(stores.library, stores.learning,
                        importNavigationRequest = startup.importNavigationRequest,
                        onImportNavigationHandled = startup::consumeImportNavigation,
                        onImportEdition = { editionPicker.launch(null) },
                    ) { picker.launch(arrayOf("application/octet-stream", "application/x-wikblb", "*/*")) }
                } else {
                    Surface(Modifier.fillMaxSize()) {
                        Column(
                            Modifier.fillMaxSize().padding(24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically)
                        ) {
                            if (startup.failed) {
                                Text("Unable to open your library.")
                                Button(onClick = startup::retry) { Text("Try again") }
                            } else {
                                CircularProgressIndicator()
                                Text("Opening your library...")
                            }
                        }
                    }
                }
            }
        }
        if (savedInstanceState == null) handle(intent)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }
    override fun onStop() { SpeechPlayback.stop(); MediaPlayback.stop(); super.onStop() }
    override fun onDestroy() { SpeechPlayback.close(); super.onDestroy() }
    private fun handle(intent: Intent) {
        if (intent.action == Intent.ACTION_VIEW) intent.data?.let { startup.import(it, showLibrary = true) }
        if (intent.action == Intent.ACTION_SEND) intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { startup.import(it, showLibrary = true) }
    }
}
