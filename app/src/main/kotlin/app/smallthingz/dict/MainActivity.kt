package app.smallthingz.dict

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts

class MainActivity : ComponentActivity() {
    private lateinit var library: LibraryStore
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        library = LibraryStore.get(this)
        val learning = LearningStore.get(this)
        val picker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> uri?.let(::import) }
        setContent { DictTheme(learning.data.settings.darkMode) {
            DictApp(library, learning) { picker.launch(arrayOf("application/octet-stream", "application/x-wikblb", "*/*")) }
        } }
        if (savedInstanceState == null) handle(intent)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }
    override fun onStop() { SpeechPlayback.stop(); MediaPlayback.stop(); super.onStop() }
    override fun onDestroy() { SpeechPlayback.close(); super.onDestroy() }
    private fun handle(intent: Intent) {
        if (intent.action == Intent.ACTION_VIEW) intent.data?.let(::import)
        if (intent.action == Intent.ACTION_SEND) intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let(::import)
    }
    private fun import(uri: Uri) {
        library.importFile(name = {
            contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0).orEmpty() else ""
            }.orEmpty()
        }) { requireNotNull(contentResolver.openInputStream(uri)) { "Cannot open dictionary" } }
    }
}
