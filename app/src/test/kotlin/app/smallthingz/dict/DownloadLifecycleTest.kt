package app.smallthingz.dict

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class DownloadLifecycleTest {
    @Test fun cancelTargetsActiveImportWhileRefreshWaits() = runBlocking {
        withTimeout(5_000) {
            val operations = LibraryOperationOwner(Mutex())
            val events = mutableListOf<String>()
            val refreshStarted = CompletableDeferred<Unit>()
            val finishRefresh = CompletableDeferred<Unit>()
            val importing = launch(start = CoroutineStart.UNDISPATCHED) {
                operations.run {
                    events += "import started"
                    try { awaitCancellation() }
                    finally { events += "import cleaned" }
                }
            }
            val refreshing = launch(start = CoroutineStart.UNDISPATCHED) {
                operations.run {
                    events += "refresh started"
                    refreshStarted.complete(Unit)
                    finishRefresh.await()
                }
            }
            assertSame(importing, operations.active)
            assertFalse(refreshStarted.isCompleted)

            val captured = operations.active
            assertNull(cancelOwnedDownload({}, { captured?.cancel() }))
            importing.join()
            refreshStarted.await()
            assertTrue(importing.isCancelled)
            assertTrue(refreshing.isActive)
            assertSame(refreshing, operations.active)
            assertEquals(listOf("import started", "import cleaned", "refresh started"), events)

            finishRefresh.complete(Unit)
            refreshing.join()
            assertNull(operations.active)
        }
    }

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

    @Test fun successfulOwnershipCommitKeepsTheNewDownload() {
        val state = Record(); state.values = emptyMap(); val calls = mutableListOf<String>()
        val record = mapOf<String, Any>("downloadId" to 42L, "downloadUrl" to "https://example.test/new.wikblb", "downloadBytes" to 456L, "downloadHash" to "b".repeat(64))
        val id = enqueueOwnedDownload(state.lock, { calls += "enqueue"; 42L }, {
            assertEquals(42L, it); assertTrue(Thread.holdsLock(state.lock))
            calls += "commit"; state.values = record; true
        }, { fail("A successful ownership commit must not remove its download") })
        assertEquals(42L, id); assertEquals(listOf("enqueue", "commit"), calls); assertEquals(record, state.values)
    }

    @Test fun failedOwnershipCommitRemovesOnlyTheNewDownload() {
        val state = Record(); val record = state.values; state.values = emptyMap()
        val calls = mutableListOf<String>(); val durable: Map<String, Any> = emptyMap()
        val caught = assertThrows(IOException::class.java) {
            enqueueOwnedDownload(state.lock, { calls += "enqueue"; 7L }, {
                assertEquals(7L, it); calls += "commit"; state.values = record; false
            }, { id ->
                assertFalse(Thread.holdsLock(state.lock)); calls += "remove"
                state.remove(id) { assertEquals(7L, it); assertEquals(record, state.values); assertTrue(durable.isEmpty()) }
            })
        }
        assertEquals(listOf("enqueue", "commit", "remove"), calls)
        assertTrue(caught.message!!.contains("cancelled")); assertTrue(state.values.isEmpty()); assertTrue(durable.isEmpty())
    }

    @Test fun failedCommitAndRemovalKeepExactOwnershipForCancelRetry() {
        val state = Record(); val record = state.values; state.values = emptyMap()
        val cleanup = IOException("provider unavailable"); var cancelled = false
        val caught = assertThrows(IOException::class.java) {
            enqueueOwnedDownload(state.lock, { 7L }, { state.values = record; false }, { id -> state.remove(id) { throw cleanup } })
        }
        assertSame(cleanup, caught.cause); assertEquals(record, state.values)
        assertTrue(caught.message!!.contains("Keep the app open")); assertTrue(caught.message!!.contains("Cancel"))
        val retry = cancelOwnedDownload({ state.remove { assertEquals(7L, it) } }, { cancelled = true })
        assertNull(retry); assertTrue(cancelled); assertTrue(state.values.isEmpty())
    }

    @Test fun failedCommitCompensationCannotClearAReplacement() {
        val state = Record(); val record = state.values; state.values = emptyMap()
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val executor = Executors.newSingleThreadExecutor()
        try {
            val pending = executor.submit<IOException> {
                assertThrows(IOException::class.java) {
                    enqueueOwnedDownload(state.lock, { 7L }, { state.values = record; false }, { id -> state.remove(id) {
                        assertEquals(7L, it); assertFalse(Thread.holdsLock(state.lock)); entered.countDown(); check(release.await(5, TimeUnit.SECONDS))
                    } })
                }
            }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val replacement = record + mapOf("downloadId" to 9L, "downloadUrl" to "https://example.test/replacement.wikblb")
            synchronized(state.lock) { state.values = replacement }
            release.countDown(); assertTrue(pending.get(5, TimeUnit.SECONDS).message!!.contains("cancelled"))
            assertEquals(replacement, state.values)
        } finally { release.countDown(); executor.shutdownNow(); assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS)) }
    }

    @Test fun failedEnqueueDoesNotCommitOrRemoveAnUncreatedDownload() {
        val failure = IOException("enqueue failed"); var committed = false; var removed = false
        val caught = assertThrows(IOException::class.java) {
            enqueueOwnedDownload(Any(), { throw failure }, { committed = true; true }, { removed = true })
        }
        assertSame(failure, caught); assertFalse(committed); assertFalse(removed)
    }

    @Test fun failedCommitCleanupCancellationPreservesOwnership() {
        val state = Record(); val record = state.values; state.values = emptyMap()
        val cancellation = CancellationException("cancelled during removal")
        val caught = assertThrows(CancellationException::class.java) {
            enqueueOwnedDownload(state.lock, { 7L }, { state.values = record; false }, { id -> state.remove(id) { throw cancellation } })
        }
        assertSame(cancellation, caught); assertEquals(record, state.values)
    }
}
