package app.smallthingz.dict

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException

/** Opening installed storage and refreshing a catalogue have independent outcomes. */
internal class LibraryFailureState {
    var initializationError by mutableStateOf<String?>(null)
        private set
    private var operationMessage by mutableStateOf<String?>(null)
    private var catalogueOwnsError = false
    var operationError: String?
        get() = operationMessage
        set(value) {
            operationMessage = value
            catalogueOwnsError = false
        }

    fun publishCatalogueError(message: String?) {
        operationError = message
        catalogueOwnsError = message != null
    }

    fun clearCatalogueError() {
        if (catalogueOwnsError) operationError = null
    }

    suspend fun initialize(
        open: suspend () -> Unit,
        publishFailure: suspend (() -> Unit) -> Unit = { change -> change() },
    ): Boolean = try {
        open()
        true
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        publishFailure {
            initializationError = "Unable to open your library. Restart the app to try again."
        }
        false
    }
}
