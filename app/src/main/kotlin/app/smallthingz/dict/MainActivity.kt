package app.smallthingz.dict

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.IntentCompat
import androidx.core.content.edit
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

sealed interface DocumentState {
    data object Empty : DocumentState
    data class Loading(val name: String) : DocumentState
    data class Loaded(val results: Results, val uri: Uri?, val name: String) : DocumentState
    data class Failed(val message: String) : DocumentState
}

class MainActivity : ComponentActivity() {
    private lateinit var learning: LearningStore
    private lateinit var picker: ActivityResultLauncher<Array<String>>
    private var document by mutableStateOf<DocumentState>(DocumentState.Empty)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        learning = LearningStore(this)
        picker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            if (uri != null) {
                runCatching { contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                open(uri, persist = true)
            }
        }
        setContent {
            DictTheme(learning.data.settings.darkMode) {
                DictApp(
                    document = document,
                    learning = learning,
                    onOpen = { picker.launch(arrayOf("application/json", "text/plain")) },
                    onReload = { (document as? DocumentState.Loaded)?.uri?.let { open(it, false) } },
                )
            }
        }
        val incoming = uriFrom(intent)
        when {
            incoming != null -> open(incoming, persist = true)
            else -> getSharedPreferences("dict.files", MODE_PRIVATE).getString("last", null)
                ?.let(Uri::parse)?.let { open(it, persist = false) }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        uriFrom(intent)?.let { open(it, persist = true) }
    }
    private fun open(uri: Uri, persist: Boolean) {
        val name = uri.lastPathSegment?.substringAfterLast('/') ?: "Compiled dictionary"
        document = DocumentState.Loading(name)
        lifecycleScope.launch {
            val loaded = runCatching { withContext(Dispatchers.IO) { ExportDocument.decode(readBounded(uri)) } }
            document = loaded.fold(
                onSuccess = { DocumentState.Loaded(it, uri, name) },
                onFailure = { DocumentState.Failed(it.message ?: "Could not open this compiled dictionary package.") },
            )
            if (loaded.isSuccess && persist) getSharedPreferences("dict.files", MODE_PRIVATE).edit { putString("last", uri.toString()) }
        }
    }

    private fun readBounded(uri: Uri): ByteArray {
        contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "Unable to read this document." }
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(32 * 1024)
            var total = 0
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                total += count
                require(total <= ExportDocument.MAX_BYTES) { "Dictionary package is larger than 64 MiB." }
                output.write(buffer, 0, count)
            }
            return output.toByteArray()
        }
    }
    private fun uriFrom(intent: Intent?): Uri? {
        if (intent == null) return null
        return when (intent.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                ?: intent.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
            else -> null
        }
    }
}
