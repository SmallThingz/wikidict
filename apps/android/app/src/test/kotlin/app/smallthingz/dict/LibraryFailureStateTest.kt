package app.smallthingz.dict

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class LibraryFailureStateTest {
    @Test fun catalogSuccessCannotEraseFailedInitialization() = runBlocking {
        val state = LibraryFailureState()
        val opened = CompletableDeferred<Unit>()
        val initialization = async { state.initialize(open = { opened.await() }) }
        state.operationError = "Earlier catalogue failure"
        opened.completeExceptionally(IOException("fixture storage unavailable"))
        assertFalse(initialization.await())
        val startupError = state.initializationError
        assertEquals("Unable to open your library. Restart the app to try again.", startupError)
        // The real operation start and successful catalogue publication both clear this channel.
        state.operationError = null
        assertEquals(startupError, state.initializationError)
        assertNull(state.operationError)
        state.operationError = "Catalogue unavailable"
        assertEquals(startupError, state.initializationError)
        assertEquals("Catalogue unavailable", state.operationError)
        state.operationError = null
        assertEquals(startupError, state.initializationError)
    }

    @Test fun successfulOpenDoesNotInventAnInitializationFailure() = runBlocking {
        val state = LibraryFailureState()
        var opens = 0
        assertTrue(state.initialize(open = { opens++ }))
        assertEquals(1, opens)
        assertNull(state.initializationError)
        state.operationError = "Catalogue unavailable"
        state.operationError = null
        assertNull(state.initializationError)
        assertNull(state.operationError)
    }

    @Test fun cancelledInitializationDoesNotPublishAStorageFailure() = runBlocking {
        val state = LibraryFailureState()
        var publications = 0
        try {
            state.initialize(open = { throw CancellationException("fixture cancelled") },
                publishFailure = { change -> publications++; change() })
            fail("Cancellation must propagate")
        } catch (_: CancellationException) { }
        assertEquals(0, publications)
        assertNull(state.initializationError)
    }
}
