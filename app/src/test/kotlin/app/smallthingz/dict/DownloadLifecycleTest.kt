package app.smallthingz.dict

import kotlinx.coroutines.CancellationException
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class DownloadLifecycleTest {
    private class Record {
        val lock = Any()
        var values: Map<String, Any> = mapOf("downloadId" to 7L, "downloadUrl" to "https://example.test/dictionary.wikblb", "downloadBytes" to 123L, "downloadHash" to "a".repeat(64))
        fun id() = values["downloadId"] as? Long ?: -1L
        fun remove(id: Long = 7L, action: (Long) -> Unit) = removeOwnedDownload(id, lock, { this.id() }, action) { values = emptyMap() }
    }

    @Test fun failedRemovalRetainsExactRecordForRetry() {
        val state = Record(); val before = state.values; val failure = IOException("provider unavailable")
        val caught = assertThrows(IOException::class.java) { state.remove { assertEquals(7L, it); throw failure } }
        assertSame(failure, caught); assertEquals(before, state.values)
        state.remove { assertEquals(7L, it) }
        assertTrue(state.values.isEmpty())
    }

    @Test fun successfulRemovalClearsOnlyAfterManagerReturns() {
        val state = Record(); val before = state.values; val calls = mutableListOf<Long>()
        state.remove { calls += it; assertEquals(before, state.values) }
        assertEquals(listOf(7L), calls); assertTrue(state.values.isEmpty())
    }

    @Test fun staleWatcherCannotClearReplacementDuringRemoval() {
        val state = Record(); val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val pending = executor.submit { state.remove { assertEquals(7L, it); entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) } }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val replacement = mapOf<String, Any>("downloadId" to 9L, "downloadUrl" to "https://example.test/new.wikblb", "downloadBytes" to 456L, "downloadHash" to "b".repeat(64))
            synchronized(state.lock) { state.values = replacement }
            release.countDown(); pending.get(5, TimeUnit.SECONDS)
            assertEquals(replacement, state.values)
        } finally { release.countDown(); executor.shutdownNow(); assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS)) }
    }

    @Test fun alreadyStaleWatcherNeverClearsNewerId() {
        val state = Record(); state.values = state.values + ("downloadId" to 9L); val before = state.values
        state.remove(7L) { assertEquals(7L, it) }
        assertEquals(before, state.values)
    }

    @Test fun ordinaryFailureRetainsRecordAndBothErrorsWhenRemovalFails() {
        val state = Record(); val before = state.values
        val original = IOException("read failed"); val cleanup = IOException("remove failed")
        val caught = assertThrows(IOException::class.java) { failOwnedDownload(original) { state.remove { throw cleanup } } }
        assertSame(original, caught); assertArrayEquals(arrayOf(cleanup), caught.suppressed); assertEquals(before, state.values)
    }

    @Test fun cancellationNeverEntersOrdinaryFailureCleanup() {
        val cancellation = CancellationException("cancelled"); var removed = false
        val caught = assertThrows(CancellationException::class.java) { failOwnedDownload(cancellation) { removed = true } }
        assertSame(cancellation, caught); assertFalse(removed)
    }

    @Test fun cleanupCancellationRemainsCancellation() {
        val cancellation = CancellationException("cancelled during cleanup")
        val caught = assertThrows(CancellationException::class.java) { failOwnedDownload(IOException("read failed")) { throw cancellation } }
        assertSame(cancellation, caught)
    }

    @Test fun failedCancelKeepsRecordAndWatcherAvailableForRetry() {
        val state = Record(); val before = state.values; val failure = IOException("remove failed"); var cancelled = false
        val reported = cancelOwnedDownload({ state.remove { throw failure } }, { cancelled = true })
        assertSame(failure, reported); assertEquals(before, state.values); assertFalse(cancelled)
    }

    @Test fun successfulCancelTargetsTheCapturedOperation() {
        val state = Record(); var oldCancelled = false; var newCancelled = false
        var current: () -> Unit = { oldCancelled = true }; val captured = current
        val reported = cancelOwnedDownload({ state.remove { current = { newCancelled = true } } }, captured)
        assertNull(reported); assertTrue(oldCancelled); assertFalse(newCancelled); assertTrue(state.values.isEmpty())
        current(); assertTrue(newCancelled)
    }
}
