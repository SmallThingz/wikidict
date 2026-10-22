package app.smallthingz.dict

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class DownloadLifecycleTest {
    @Test fun importedDictionaryHashPreservesDigestAcrossShortReads() = runBlocking {
        var reads = 0
        var closed = false
        val input = object : ByteArrayInputStream("abc".toByteArray()) {
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                reads++
                return super.read(bytes, offset, minOf(length, 1))
            }
            override fun close() { closed = true; super.close() }
        }
        val digest = input.use { hashImportedDictionary(it) }
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", digest)
        assertEquals(4, reads)
        assertTrue(closed)
    }

    @Test fun importedDictionaryHashCancellationStopsBeforeAnotherRead() = runBlocking {
        var reads = 0
        var returned = false
        var closed = false
        val hashing = launch(start = CoroutineStart.UNDISPATCHED) {
            val owner = currentCoroutineContext().job
            val input = object : ByteArrayInputStream("abcdef".toByteArray()) {
                override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                    reads++
                    val count = super.read(bytes, offset, minOf(length, 1))
                    if (reads == 1) owner.cancel(CancellationException("cancel during hash"))
                    return count
                }
                override fun close() { closed = true; super.close() }
            }
            input.use { hashImportedDictionary(it) }
            returned = true
        }
        hashing.join()
        assertTrue(hashing.isCancelled)
        assertEquals(1, reads)
        assertFalse(returned)
        assertTrue(closed)
    }


    @Test fun importedDictionaryHashCancellationAtEofDoesNotReturnDigest() = runBlocking {
        var reads = 0
        var returned = false
        var closed = false
        val hashing = launch(start = CoroutineStart.UNDISPATCHED) {
            val owner = currentCoroutineContext().job
            val input = object : ByteArrayInputStream("abc".toByteArray()) {
                override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                    reads++
                    val count = super.read(bytes, offset, length)
                    if (count < 0) owner.cancel(CancellationException("cancel at hash EOF"))
                    return count
                }
                override fun close() { closed = true; super.close() }
            }
            input.use { hashImportedDictionary(it) }
            returned = true
        }
        hashing.join()
        assertTrue(hashing.isCancelled)
        assertEquals(2, reads)
        assertFalse(returned)
        assertTrue(closed)
    }

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

    @Test fun cancellationAfterBusyPublicationCleansBeforeQueuedOperationStarts() = runBlocking {
        withTimeout(5_000) {
            // Explicit queues stop at the actual UI-to-owner return dispatch;
            // no sleeps, threads, Android Main replacement or timing race.
            class QueueDispatcher : kotlinx.coroutines.CoroutineDispatcher() {
                private val queued = java.util.ArrayDeque<Runnable>()
                override fun dispatch(context: kotlin.coroutines.CoroutineContext, block: Runnable) { queued.addLast(block) }
                fun next() { check(queued.isNotEmpty()); queued.removeFirst().run() }
                fun drain() {
                    repeat(64) { if (queued.isEmpty()) return; next() }
                    check(queued.isEmpty()) { "Dispatcher exceeded bounded lifecycle schedule" }
                }
            }
            val worker = QueueDispatcher()
            val ui = QueueDispatcher()
            val operations = LibraryOperationOwner(Mutex())
            var busy: String? = null
            var bodyRan = false
            var cleanupCalls = 0
            var transferDetail: String? = null
            var nextRan = false
            val owned = mutableListOf<kotlinx.coroutines.Job>()
            try {
                val first = launch(worker) {
                    operations.run(
                        start = { kotlinx.coroutines.withContext(ui) { busy = "Importing dictionary"; transferDetail = "Reading" } },
                        finish = { kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable + ui) {
                            busy = null
                            transferDetail = null
                            cleanupCalls++
                        } },
                    ) { bodyRan = true }
                }
                owned += first
                worker.next() // Enter owner; queue first UI publication.
                assertSame(first, operations.active)
                val next = launch(worker) {
                    operations.run {
                        assertEquals(1, cleanupCalls)
                        assertNull(busy)
                        assertNull(transferDetail)
                        assertSame(currentCoroutineContext().job, operations.active)
                        nextRan = true
                    }
                }
                owned += next
                worker.next() // Queue behind the held mutex, before publication.
                ui.next() // Publish busy; worker return remains queued.
                assertEquals("Importing dictionary", busy)
                assertFalse(bodyRan)
                first.cancel()
                worker.drain() // Cancelled return must enter cleanup, awaiting UI.
                assertFalse(nextRan)
                ui.drain()
                worker.drain()
                first.join(); next.join()
                assertTrue(first.isCancelled)
                assertFalse(bodyRan)
                assertEquals(1, cleanupCalls)
                assertNull(busy)
                assertNull(transferDetail)
                assertTrue(nextRan)
                assertTrue(next.isCompleted && !next.isCancelled)
                assertNull(operations.active)
            } finally {
                // Assertions can fail with a child suspended on either queue.
                // Cancel every created job and service both dispatchers so the
                // enclosing structured scope never waits on an undrained child.
                owned.forEach { it.cancel() }
                repeat(8) { worker.drain(); ui.drain() }
                check(owned.all { it.isCompleted }) { "Owned lifecycle jobs did not finish during teardown" }
            }
        }
    }

    @Test fun delayedCancelCannotOverwriteACompletedNewerOperation() = runBlocking {
        withTimeout(5_000) {
            for (captureActive in listOf(true, false)) for (removeFails in listOf(true, false)) {
                val worker = CancellationQueueDispatcher()
                val cancelWorker = CancellationQueueDispatcher()
                val ui = CancellationQueueDispatcher()
                val operations = LibraryOperationOwner(Mutex())
                val releaseFirst = CompletableDeferred<Unit>()
                val owned = mutableListOf<kotlinx.coroutines.Job>()
                var message: String? = "Old operation"
                var currentDownload = 7L
                val removed = mutableListOf<Long>()
                try {
                    if (captureActive) {
                        owned += launch(worker) { operations.run { releaseFirst.await() } }
                        worker.drain()
                    }
                    val captured = operations.capture()
                    val capturedId = currentDownload
                    val cancellation = launch(cancelWorker) {
                        val failure = cancelOwnedDownload({
                            removed += capturedId
                            if (removeFails) throw IOException("Old removal failed")
                            removeOwnedDownload(capturedId, Any(), { currentDownload }, {}, { currentDownload = -1 })
                        }, { captured.job?.cancel() })
                        kotlinx.coroutines.withContext(ui) { operations.publishIfCurrent(captured) {
                            message = failure?.message
                        } }
                    }
                    owned += cancellation
                    val next = launch(worker) { operations.run {
                        currentDownload = 9L
                        kotlinx.coroutines.withContext(ui) { message = "New operation failed" }
                    } }
                    owned += next
                    worker.drain() // The next operation waits if the first still owns the mutex.
                    releaseFirst.complete(Unit)
                    worker.drain(); ui.drain(); worker.drain()
                    assertTrue(next.isCompleted && !next.isCancelled)
                    assertNull(operations.active) // Both operations finished; null identity is insufficient.
                    assertEquals("New operation failed", message)
                    cancelWorker.drain(); ui.drain(); cancelWorker.drain()
                    assertTrue(cancellation.isCompleted && !cancellation.isCancelled)
                    assertEquals(listOf(7L), removed)
                    assertEquals(9L, currentDownload)
                    assertEquals("New operation failed", message)
                    assertNull(operations.active)
                } finally {
                    owned.forEach { it.cancel() }
                    repeat(8) { worker.drain(); cancelWorker.drain(); ui.drain() }
                    check(owned.all { it.isCompleted })
                }
            }
        }
    }

    @Test fun currentEpochCancelStillReportsSuccessAndFailureWithOrWithoutActiveJob() = runBlocking {
        withTimeout(5_000) {
            for (captureActive in listOf(true, false)) for (removeFails in listOf(true, false)) {
                val worker = CancellationQueueDispatcher()
                val ui = CancellationQueueDispatcher()
                val operations = LibraryOperationOwner(Mutex())
                val owned = mutableListOf<kotlinx.coroutines.Job>()
                var message: String? = "Previous error"
                var removed = false
                try {
                    val active = if (captureActive) launch(worker) { operations.run { awaitCancellation() } }
                        .also { owned += it; worker.drain() } else null
                    val captured = operations.capture()
                    assertSame(active, captured.job)
                    val cancellation = launch(worker) {
                        val failure = cancelOwnedDownload({
                            removed = true
                            if (removeFails) throw IOException("Removal failed")
                        }, { captured.job?.cancel() })
                        kotlinx.coroutines.withContext(ui) { operations.publishIfCurrent(captured) {
                            message = failure?.message
                        } }
                    }
                    owned += cancellation
                    worker.drain(); ui.drain(); worker.drain()
                    assertTrue(removed)
                    assertTrue(cancellation.isCompleted && !cancellation.isCancelled)
                    assertEquals(if (removeFails) "Removal failed" else null, message)
                    if (active != null) {
                        if (removeFails) { assertTrue(active.isActive); assertSame(active, operations.active) }
                        else { assertTrue(active.isCancelled); assertNull(operations.active) }
                    } else assertNull(operations.active)
                } finally {
                    owned.forEach { it.cancel() }
                    repeat(8) { worker.drain(); ui.drain() }
                    check(owned.all { it.isCompleted })
                }
            }
        }
    }

    private class CancellationQueueDispatcher : kotlinx.coroutines.CoroutineDispatcher() {
        private val queued = java.util.ArrayDeque<Runnable>()
        override fun dispatch(context: kotlin.coroutines.CoroutineContext, block: Runnable) { queued.addLast(block) }
        fun drain() {
            repeat(64) { if (queued.isEmpty()) return; queued.removeFirst().run() }
            check(queued.isEmpty()) { "Dispatcher exceeded bounded cancellation schedule" }
        }
    }

    private class ClearRecord {
        val lock = Any()
        val owner = DownloadClearOwner()
        var values: Map<String, Any?> = mapOf("downloadId" to 7L, "downloadUrl" to "https://example.test/owned.wikblb",
            "downloadLabel" to "Owned", "downloadBytes" to 123L, "downloadHash" to "a".repeat(64))
        var retained = true
        fun id() = synchronized(lock) { owner.id(values["downloadId"] as? Long ?: -1L) }
        fun clear(id: Long = 7L, commit: () -> Boolean, restore: (Map<String, Any?>) -> Boolean) =
            removeOwnedDownload(id, lock, { this.id() }, {}) {
                owner.clear(id, lock, { values["downloadId"] as? Long ?: -1L }, { values.toMap() },
                    { retained = it }, commit, restore)
            }
    }

    @Test fun failedClearCommitRestoresExactPresentFieldsAndKeepsCancelRetryable() {
        for (restoreSucceeds in listOf(true, false)) for (omitHash in listOf(true, false)) {
            val state = ClearRecord()
            if (omitHash) state.values = state.values - "downloadHash"
            val saved = state.values
            var cancelled = false
            val failure = cancelOwnedDownload({ state.clear(commit = {
                assertTrue(Thread.holdsLock(state.lock)); state.values = emptyMap(); false
            }, restore = {
                assertTrue(Thread.holdsLock(state.lock)); assertEquals(saved, it); state.values = it; restoreSucceeds
            }) }, { cancelled = true })
            assertTrue(failure is IOException); assertTrue(failure!!.message!!.contains("uncertain"))
            assertEquals(if (restoreSucceeds) 0 else 1, failure.suppressed.size)
            assertEquals(saved, state.values); assertEquals(7L, state.id()); assertTrue(state.retained); assertFalse(cancelled)
            val retry = cancelOwnedDownload({ state.clear(commit = { state.values = emptyMap(); true },
                restore = { error("Successful clearing must not restore") }) }, { cancelled = true })
            assertNull(retry); assertTrue(cancelled); assertTrue(state.values.isEmpty()); assertEquals(-1L, state.id()); assertFalse(state.retained)
        }
    }

    @Test fun clearAndRestorationExceptionsKeepOriginalFailureAndPendingRetryOwner() {
        val state = ClearRecord(); val saved = state.values
        val original = IOException("clear storage unavailable"); val restoration = IOException("restore unavailable")
        val caught = assertThrows(IOException::class.java) {
            state.clear(commit = { state.values = emptyMap(); throw original }, restore = { throw restoration })
        }
        assertSame(original, caught.cause); assertArrayEquals(arrayOf(restoration), caught.suppressed)
        assertTrue(state.values.isEmpty()); assertEquals(7L, state.id()); assertTrue(state.retained)
        state.clear(commit = { state.values = emptyMap(); true }, restore = { error("No restore after successful retry") })
        assertFalse(state.retained); assertEquals(-1L, state.id()); assertTrue(state.values.isEmpty())
        assertEquals(7L, saved["downloadId"])
    }

    @Test fun failedClearCannotRestoreOverAReplacementOrResurrectItsOldOwner() {
        val state = ClearRecord()
        val replacement = state.values + mapOf("downloadId" to 9L, "downloadLabel" to "Replacement")
        var restored = false
        assertThrows(IOException::class.java) {
            state.clear(commit = { state.values = replacement; false }, restore = { restored = true; state.values = it; true })
        }
        assertFalse(restored); assertEquals(replacement, state.values); assertEquals(9L, state.id()); assertTrue(state.retained)
        state.clear(id = 7L, commit = { error("Stale clear must not commit") }, restore = { error("Stale clear must not restore") })
        assertEquals(replacement, state.values)
        state.clear(id = 9L, commit = { state.values = emptyMap(); true }, restore = { error("No restoration required") })
        assertEquals(-1L, state.id()); assertFalse(state.retained); assertTrue(state.values.isEmpty())
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
