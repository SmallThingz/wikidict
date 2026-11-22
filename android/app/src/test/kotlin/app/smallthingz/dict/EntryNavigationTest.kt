package app.smallthingz.dict

import java.io.IOException
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test

class EntryNavigationTest {
    private fun hit(title: String) = WordHit("fixture", title, "English", "entry", 0, 1)
    private fun entry(title: String) = Entry(title, emptyList(), "entry", "English", "en", emptyList(), emptyList())
    private fun word(title: String, dictionary: String? = "fixture") =
        SavedWord(title, title, "English", "entry", "", dictionary = dictionary)

    /** Deliberately ignores cancellation, like a completion already in flight. */
    private class Completion<T> {
        val started = CompletableDeferred<Unit>()
        private var continuation: Continuation<T>? = null
        var delivered = false
            private set

        suspend fun await(): T = suspendCoroutine { next ->
            check(continuation == null)
            continuation = next
            started.complete(Unit)
        }

        fun succeed(value: T) {
            val next = checkNotNull(continuation)
            continuation = null
            delivered = true
            next.resume(value)
        }

        fun fail(error: Exception) {
            val next = checkNotNull(continuation)
            continuation = null
            delivered = true
            next.resumeWithException(error)
        }

        fun releaseIfPending(value: T) {
            continuation?.let { next -> continuation = null; next.resume(value) }
        }
    }

    private inner class Harness(scope: CoroutineScope, state: EntryNavigationState = EntryNavigationState(),
        choices: (suspend (EntryLink, Entry) -> List<WordHit>)? = null,
        choose: suspend (EntryLink, List<WordHit>) -> WordHit? = { _, _ -> null }) {
        val dictionaries = mutableSetOf("fixture")
        var read: suspend (WordHit) -> Entry = { entry(it.title) }
        var link: suspend (EntryLink, Entry) -> WordHit? = { _, _ -> null }
        var saved: suspend (SavedWord) -> WordHit? = { null }
        var random: suspend () -> WordHit? = { null }
        var initial: suspend () -> WordHit? = { null }
        var showError: suspend (String) -> Unit = {}
        var screen = "Dictionary"
        var title: String? = null
        var target = ""
        var targetComponents = EntryLink("")
        var loading = false
        val loadingEvents = mutableListOf<Boolean>()
        val history = mutableListOf<String>()
        val errors = mutableListOf<String>()
        val reads = mutableListOf<String>()
        val exactReads = mutableListOf<WordHit>()
        var visits = state.snapshot()
        var restoredHit: WordHit? = null
        val navigation = EntryNavigation(
            scope, { hit ->
                exactReads += hit
                reads += hit.title
                read(hit).let { it.copy(origin = it.origin ?: hit, contentDictionary = it.contentDictionary ?: hit.dictionary) }
            }, { target, entry -> link(target, entry) },
            { saved(it) }, { random() }, { initial() },
            { hit, entry, fragment ->
                title = entry.title
                target = fragment.target
                targetComponents = fragment
                history += hit.title
                screen = "Dictionary"
            },
            { loading = it; loadingEvents += it },
            { errors += it; showError(it) },
            installed = { it in dictionaries },
            visitsChanged = { visits = it },
            state = state,
            linkChoices = choices,
            chooseLink = choose,
            restore = { hit, entry ->
                restoredHit = hit
                title = entry.title
                target = ""
                targetComponents = EntryLink("")
                history += hit.title
                screen = "Dictionary"
            },
        )
    }

    @Test fun lookupAndCommitCarrySeparateComponentsAndBackKeepsExactVisit() = runBlocking {
        withTimeout(5_000) {
            val h = Harness(this)
            h.navigation.open(hit("source")).join()
            val actions = listOf(EntryLink("Page#Noun"), EntryLink("Page#literal", ""),
                EntryLink("Page#literal%23?&語", "Noun#part"))
            for (action in actions) {
                var observed: EntryLink? = null
                h.link = { target, _ -> observed = target; hit(target.title) }
                h.navigation.openLink(action, entry("source")).join()
                assertEquals(action, observed)
                assertEquals(action, h.targetComponents)
                assertEquals(action.title, h.title)
                assertTrue(h.navigation.goBack())
                yield()
                assertEquals("source", h.title)
                assertEquals(EntryLink(""), h.targetComponents)
            }
        }
    }

    @Test fun linkedBackRereadsExactOwnerAndRestoresTheOriginalVisit() = runBlocking {
        withTimeout(5_000) {
            val state = EntryNavigationState()
            val h = Harness(this, state)
            h.dictionaries += "other"
            val a = hit("same")
            val b = a.copy(dictionary = "other")
            h.navigation.open(a).join()
            val originalId = h.visits.currentId
            h.link = { _, _ -> b }
            h.navigation.openLink(EntryLink("same#Noun"), entry("same")).join()
            val secondId = requireNotNull(h.visits.currentId)
            assertNotEquals(originalId, secondId)
            val committed = state.snapshot()
            // A successor owns committed state even before old disposal/cancellation.
            val late = Completion<Entry>()
            h.read = { late.await() }
            val pending = h.navigation.openLink(EntryLink("late"), entry("same"))
            late.started.await()
            val recreated = Harness(this, state)
            recreated.dictionaries += "other"
            assertEquals(committed, recreated.visits)
            assertFalse(recreated.loading)
            late.succeed(entry("late"))
            pending.join()
            h.navigation.cancel()
            assertEquals(listOf("same", "same"), h.history)
            assertTrue(h.errors.isEmpty())
            assertEquals(committed, state.snapshot())
            assertTrue(recreated.navigation.goBack())
            while (recreated.loading) yield()
            assertEquals(listOf(a, b, b), h.exactReads)
            assertEquals(listOf(a), recreated.exactReads)
            assertEquals(a, recreated.restoredHit)
            assertEquals(originalId, recreated.visits.currentId)
            assertEquals(setOf(originalId), recreated.visits.retainedIds)
            assertEquals("", recreated.target) // Never replay the consumed fragment.
            assertFalse(recreated.navigation.goBack())
            recreated.link = { _, _ -> b }
            recreated.navigation.openLink(EntryLink("same"), entry("same")).join()
            assertTrue(requireNotNull(recreated.visits.currentId) > secondId)
            // Keep the existing 32 previous visits plus one current visit bound.
            repeat(35) { recreated.navigation.openLink(EntryLink("same"), entry("same")).join() }
            assertEquals(33, recreated.visits.retainedIds.size)
            recreated.navigation.open(a).join()
            assertEquals(1, recreated.visits.retainedIds.size)
            assertFalse(recreated.navigation.goBack())
        }
    }

    @Test fun backCancelsPendingLinkAndReturnWithoutPoppingOrPublishingLateResults() = runBlocking {
        withTimeout(5_000) {
            for (returning in listOf(false, true)) {
                val h = Harness(this)
                h.navigation.open(hit("A")).join()
                h.link = { _, _ -> hit("B") }
                h.navigation.openLink(EntryLink("B"), entry("A")).join()
                val before = h.visits
                val history = h.history.toList()
                val completion = Completion<Entry>()
                h.read = { completion.await() }
                val pending = if (returning) {
                    assertTrue(h.navigation.goBack()); null
                } else h.navigation.openLink(EntryLink("C"), entry("B"))
                completion.started.await()
                assertTrue(h.navigation.goBack())
                assertEquals(before, h.visits)
                completion.succeed(entry(if (returning) "A" else "C"))
                pending?.join()
                yield()
                assertEquals("B", h.title)
                assertEquals(history, h.history)
                assertTrue(h.errors.isEmpty())
                assertFalse(h.loading)
                h.read = { entry(it.title) }
                assertTrue(h.navigation.goBack())
                while (h.loading) yield()
                assertEquals("A", h.title)
            }
        }
    }

    @Test fun failedReturnAndFailedRootKeepPathButSuccessfulRootResetsIt() = runBlocking {
        withTimeout(5_000) {
            val h = Harness(this)
            h.navigation.open(hit("A")).join()
            h.link = { _, _ -> hit("B") }
            h.navigation.openLink(EntryLink("B"), entry("A")).join()
            val before = h.visits
            h.read = { throw IOException("Unavailable") }
            assertTrue(h.navigation.goBack())
            while (h.loading) yield()
            assertEquals(before, h.visits)
            assertEquals("B", h.title)
            h.navigation.open(hit("root")).join()
            assertEquals(before, h.visits)
            h.read = { entry(it.title) }
            h.navigation.open(hit("root")).join()
            assertFalse(h.visits.canGoBack)
            assertEquals(1, h.visits.retainedIds.size)
            assertFalse(h.navigation.goBack())
        }
    }

    @Test fun removedOwnersArePrunedAndPendingRootBackStillCancels() = runBlocking {
        withTimeout(5_000) {
            val h = Harness(this)
            h.dictionaries += "other"
            h.navigation.open(hit("A")).join()
            h.link = { _, _ -> hit("B").copy(dictionary = "other") }
            h.navigation.openLink(EntryLink("B"), entry("A")).join()
            h.dictionaries -= "fixture"
            h.navigation.libraryChanged()
            assertFalse(h.navigation.goBack())
            assertEquals(1, h.visits.retainedIds.size)
            h.dictionaries.clear()
            h.navigation.libraryChanged()
            assertTrue(h.visits.retainedIds.isEmpty())
            assertFalse(h.navigation.goBack())
            h.dictionaries += "fixture"
            val completion = Completion<Entry>()
            h.read = { completion.await() }
            val pending = h.navigation.open(hit("late"))
            completion.started.await()
            assertTrue(h.navigation.goBack())
            completion.fail(IOException("late failure"))
            pending.join()
            assertTrue(h.errors.isEmpty())
            assertFalse(h.navigation.goBack())

            val returning = Harness(this)
            returning.dictionaries += "other"
            returning.navigation.open(hit("A")).join()
            returning.link = { _, _ -> hit("B").copy(dictionary = "other") }
            returning.navigation.openLink(EntryLink("B"), entry("A")).join()
            val returnRead = Completion<Entry>()
            returning.read = { returnRead.await() }
            assertTrue(returning.navigation.goBack())
            returnRead.started.await()
            returning.dictionaries -= "other"
            returning.navigation.libraryChanged()
            assertFalse(returning.loading)
            assertTrue(returning.visits.retainedIds.isEmpty())
            returnRead.succeed(entry("A"))
            yield()
            assertEquals(listOf("A", "B"), returning.history)
            assertNull(returning.restoredHit)
            assertTrue(returning.errors.isEmpty())
            assertFalse(returning.navigation.goBack())
            requireNotNull(returning.navigation.openInitialIfIdle()).join()
        }
    }

    @Test fun dockAndBackInvalidatePendingReadWithoutPublishingHistory() = runBlocking {
        withTimeout(5_000) {
            for (destination in listOf("Settings", "Dictionary")) {
                val completion = Completion<Entry>()
                val h = Harness(this)
                h.screen = "Library"
                h.read = { completion.await() }
                val pending = h.navigation.open(hit("old"))
                try {
                    completion.started.await()
                    h.navigation.interrupt { h.screen = destination }
                    assertFalse(h.loading)
                    completion.succeed(entry("old"))
                    pending.join()
                    assertTrue(completion.delivered)
                    assertEquals(destination, h.screen)
                    assertNull(h.title)
                    assertTrue(h.history.isEmpty())
                    assertTrue(h.errors.isEmpty())
                } finally {
                    h.navigation.cancel()
                    completion.releaseIfPending(entry("old"))
                }
            }
        }
    }

    @Test fun aNonCooperativeOlderReadCannotReplaceTheLatestEntry() = runBlocking {
        withTimeout(5_000) {
            val old = Completion<Entry>()
            val h = Harness(this)
            h.read = { if (it.title == "old") old.await() else entry(it.title) }
            val first = h.navigation.open(hit("old"))
            try {
                old.started.await()
                h.navigation.open(hit("new")).join()
                old.succeed(entry("old"))
                first.join()
                assertTrue(old.delivered)
                assertEquals("new", h.title)
                assertEquals(listOf("new"), h.history)
                assertFalse(h.loading)
                assertTrue(h.errors.isEmpty())
            } finally {
                h.navigation.cancel()
                old.releaseIfPending(entry("old"))
            }
        }
    }

    @Test fun allOlderLookupKindsAreInvalidatedBeforeTheyCanStartARead() = runBlocking {
        withTimeout(5_000) {
            for (kind in listOf("internal", "saved", "random", "initial")) {
                val old = Completion<WordHit?>()
                val h = Harness(this)
                h.link = { _, _ -> old.await() }
                h.saved = { old.await() }
                h.random = { old.await() }
                h.initial = { old.await() }
                val pending = when (kind) {
                    "internal" -> h.navigation.openLink(EntryLink("old#Noun"), entry("source"))
                    "saved" -> h.navigation.openSaved(word("old"))
                    "random" -> h.navigation.openRandom()
                    else -> h.navigation.openInitial()
                }
                try {
                    old.started.await()
                    h.navigation.open(hit("new")).join()
                    old.succeed(hit("old"))
                    pending.join()
                    assertTrue(old.delivered)
                    assertEquals(kind, listOf("new"), h.reads)
                    assertEquals(kind, listOf("new"), h.history)
                    assertEquals("new", h.title)
                    assertTrue(h.errors.isEmpty())
                } finally {
                    h.navigation.cancel()
                    old.releaseIfPending(null)
                }
            }
        }
    }

    @Test fun laterInternalSavedAndRandomIntentsReplaceAnOlderDirectRead() = runBlocking {
        withTimeout(5_000) {
            for (kind in listOf("internal", "saved", "random")) {
                val old = Completion<Entry>()
                val h = Harness(this)
                h.read = { if (it.title == "old") old.await() else entry(it.title) }
                h.link = { _, _ -> hit("new") }
                h.saved = { hit("new") }
                h.random = { hit("new") }
                val pending = h.navigation.open(hit("old"))
                try {
                    old.started.await()
                    val latest = when (kind) {
                        "internal" -> h.navigation.openLink(EntryLink("new#Usage_notes"), entry("source"))
                        "saved" -> h.navigation.openSaved(word("new"))
                        else -> h.navigation.openRandom()
                    }
                    latest.join()
                    old.succeed(entry("old"))
                    pending.join()
                    assertEquals(kind, listOf("new"), h.history)
                    assertEquals("new", h.title)
                    assertEquals(if (kind == "internal") "new#Usage_notes" else "", h.target)
                    assertFalse(h.loading)
                } finally {
                    h.navigation.cancel()
                    old.releaseIfPending(entry("old"))
                }
            }
        }
    }

    @Test fun staleNonCooperativeErrorAndFinallyCannotClearNewLoading() = runBlocking {
        withTimeout(5_000) {
            val old = Completion<Entry>()
            val next = Completion<Entry>()
            val h = Harness(this)
            h.read = { if (it.title == "old") old.await() else next.await() }
            val first = h.navigation.open(hit("old"))
            try {
                old.started.await()
                val latest = h.navigation.open(hit("new"))
                next.started.await()
                old.fail(IOException("stale read failure"))
                first.join()
                assertTrue(old.delivered)
                assertTrue(first.isCancelled)
                assertTrue(h.errors.isEmpty())
                assertTrue(h.history.isEmpty())
                assertTrue(h.loading)
                assertEquals(listOf(true, true), h.loadingEvents)
                next.succeed(entry("new"))
                latest.join()
                assertEquals(listOf("new"), h.history)
                assertEquals(listOf(true, true, false), h.loadingEvents)
                assertFalse(h.loading)
            } finally {
                h.navigation.cancel()
                old.releaseIfPending(entry("old"))
                next.releaseIfPending(entry("new"))
            }
        }
    }

    @Test fun staleLookupFailureCannotReportAnErrorOverTheNewRead() = runBlocking {
        withTimeout(5_000) {
            val lookup = Completion<WordHit?>()
            val next = Completion<Entry>()
            val h = Harness(this)
            h.link = { _, _ -> lookup.await() }
            h.read = { next.await() }
            val first = h.navigation.openLink(EntryLink("old"), entry("source"))
            try {
                lookup.started.await()
                val latest = h.navigation.open(hit("new"))
                next.started.await()
                lookup.fail(IOException("stale lookup failure"))
                first.join()
                assertTrue(lookup.delivered)
                assertTrue(h.loading)
                assertTrue(h.errors.isEmpty())
                assertEquals(listOf("new"), h.reads)
                next.succeed(entry("new"))
                latest.join()
                assertEquals(listOf("new"), h.history)
            } finally {
                h.navigation.cancel()
                lookup.releaseIfPending(null)
                next.releaseIfPending(entry("new"))
            }
        }
    }

    @Test fun currentErrorStopsLoadingBeforeDismissalAndCannotClearNewIntent() = runBlocking {
        withTimeout(5_000) {
            val dismissal = Completion<Unit>()
            val next = Completion<Entry>()
            val h = Harness(this)
            h.showError = { dismissal.await() }
            val first = h.navigation.openLink(EntryLink("absent"), entry("source"))
            try {
                dismissal.started.await()
                assertEquals(listOf("This word is not in your installed dictionaries."), h.errors)
                assertFalse(h.loading)
                assertTrue(first.isActive)
                assertNull(h.navigation.openInitialIfIdle())
                assertTrue(h.reads.isEmpty())
                assertTrue(h.history.isEmpty())
                h.read = { next.await() }
                val latest = h.navigation.open(hit("new"))
                next.started.await()
                assertTrue(h.loading)
                assertTrue(first.isCancelled)
                dismissal.succeed(Unit)
                first.join()
                assertTrue(dismissal.delivered)
                assertTrue(h.loading)
                assertTrue(h.history.isEmpty())
                next.succeed(entry("new"))
                latest.join()
                assertEquals(listOf("new"), h.history)
                assertEquals("new", h.title)
                assertFalse(h.loading)
            } finally {
                h.navigation.cancel()
                dismissal.releaseIfPending(Unit)
                next.releaseIfPending(entry("new"))
            }
        }
    }

    @Test fun missingTargetsKeepTheirMessagesAndRandomAndInitialRemainSilent() = runBlocking {
        withTimeout(5_000) {
            val h = Harness(this)
            h.navigation.openLink(EntryLink("absent"), entry("source")).join()
            h.navigation.openSaved(word("lost", null)).join()
            h.navigation.openSaved(word("lost")).join()
            h.navigation.openRandom().join()
            h.navigation.openInitial().join()
            assertEquals(listOf(
                "This word is not in your installed dictionaries.",
                "Choose lost again from search.",
                "Install the dictionary for lost.",
            ), h.errors)
            assertTrue(h.reads.isEmpty())
            assertTrue(h.history.isEmpty())
            assertFalse(h.loading)
        }
    }

    @Test fun currentReadFailureRetainsMessageAndFallbackAndClearsLoading() = runBlocking {
        withTimeout(5_000) {
            val h = Harness(this)
            h.read = { throw IOException("record damaged") }
            h.navigation.open(hit("first")).join()
            h.read = { throw IOException() }
            h.navigation.open(hit("second")).join()
            assertEquals(listOf("record damaged", "Unable to read this word"), h.errors)
            assertTrue(h.history.isEmpty())
            assertFalse(h.loading)
        }
    }

    @Test fun currentCancellationIsNotConvertedToAReadError() = runBlocking {
        withTimeout(5_000) {
            val h = Harness(this)
            h.read = { throw CancellationException("cancelled read") }
            val job = h.navigation.open(hit("cancelled"))
            job.join()
            assertTrue(job.isCancelled)
            assertTrue(h.errors.isEmpty())
            assertTrue(h.history.isEmpty())
            assertFalse(h.loading)
        }
    }

    @Test fun removedInitialDictionaryCancelsOldReadAndLaterScreenChoiceStillWins() = runBlocking {
        withTimeout(5_000) {
            val old = Completion<Entry>()
            val refreshed = Completion<Entry>()
            val h = Harness(this)
            h.dictionaries += "old-dictionary"
            var initialHit = hit("old").copy(dictionary = "old-dictionary")
            h.initial = { initialHit }
            h.read = { if (it.title == "old") old.await() else refreshed.await() }
            val first = h.navigation.openInitial()
            try {
                old.started.await()
                // Removing the actual selection invalidates even a non-cooperative read.
                h.dictionaries -= "old-dictionary"
                h.navigation.libraryChanged()
                initialHit = hit("refreshed")
                val next = requireNotNull(h.navigation.openInitialIfIdle())
                refreshed.started.await()
                // A subsequent user action supersedes that refreshed initial selection too.
                h.navigation.interrupt { h.screen = "Settings" }
                old.succeed(entry("old"))
                first.join()
                refreshed.succeed(entry("refreshed"))
                next.join()
                assertTrue(old.delivered)
                assertTrue(refreshed.delivered)
                assertEquals(listOf("old", "refreshed"), h.reads)
                assertEquals("Settings", h.screen)
                assertNull(h.title)
                assertTrue(h.history.isEmpty())
                assertTrue(h.errors.isEmpty())
                assertFalse(h.loading)
            } finally {
                h.navigation.cancel()
                old.releaseIfPending(entry("old"))
                refreshed.releaseIfPending(entry("refreshed"))
            }
        }
    }

    @Test fun unrelatedChangesPreserveLookupAndReadAndDoNotStartInitialFallback() = runBlocking {
        withTimeout(5_000) {
            val lookup = Completion<WordHit?>()
            val body = Completion<Entry>()
            val h = Harness(this)
            h.dictionaries += "cat-dictionary"
            val catHit = hit("cat").copy(dictionary = "cat-dictionary")
            h.navigation.open(catHit).join()
            val cat = entry("cat").copy(origin = catHit, contentDictionary = catHit.dictionary)
            h.link = { _, _ -> lookup.await() }
            h.read = { body.await() }
            var initialCalls = 0
            h.initial = { initialCalls++; hit("fallback") }
            val pending = h.navigation.openLink(EntryLink("dog#Usage_notes"), cat)
            try {
                lookup.started.await()
                // The displayed cat disappears while the latest destination is still unknown.
                h.dictionaries -= "cat-dictionary"
                h.dictionaries += "unrelated-import"
                h.navigation.libraryChanged()
                assertFalse(cat.isInstalled { it in h.dictionaries })
                assertNull(h.navigation.openInitialIfIdle())
                assertTrue(h.loading)
                lookup.succeed(hit("dog"))
                body.started.await()
                h.dictionaries -= "unrelated-import"
                h.navigation.libraryChanged()
                assertNull(h.navigation.openInitialIfIdle())
                assertFalse(pending.isCancelled)
                assertTrue(h.loading)
                assertEquals(0, initialCalls)
                body.succeed(entry("dog"))
                pending.join()
                assertTrue(lookup.delivered && body.delivered)
                assertEquals("dog", h.title)
                assertEquals("dog#Usage_notes", h.target)
                assertEquals(listOf("cat", "dog"), h.history)
                assertTrue(h.errors.isEmpty())
                assertFalse(h.loading)
            } finally {
                h.navigation.cancel()
                lookup.releaseIfPending(null)
                body.releaseIfPending(entry("dog"))
            }
        }
    }

    @Test fun removedOriginOrContextCancelsReadWithoutPublishingOrAStaleError() = runBlocking {
        withTimeout(5_000) {
            for (removed in listOf("origin", "context")) for (fails in listOf(false, true)) {
                val body = Completion<Entry>()
                val nextBody = Completion<Entry>()
                val h = Harness(this)
                h.dictionaries += listOf("origin", "context")
                val oldHit = hit("old").copy(dictionary = "origin", contextDictionary = "context")
                h.read = { if (it.title == "old") body.await() else nextBody.await() }
                val pending = h.navigation.open(oldHit)
                try {
                    body.started.await()
                    h.dictionaries -= removed
                    h.navigation.libraryChanged()
                    assertTrue(pending.isCancelled)
                    val next = h.navigation.open(hit("new"))
                    nextBody.started.await()
                    if (fails) body.fail(IOException("removed record")) else body.succeed(entry("old"))
                    pending.join()
                    assertTrue(body.delivered)
                    assertTrue(h.loading)
                    assertTrue(h.history.isEmpty())
                    assertTrue(h.errors.isEmpty())
                    nextBody.succeed(entry("new"))
                    next.join()
                    assertEquals(listOf("new"), h.history)
                    assertFalse(h.loading)
                } finally {
                    h.navigation.cancel()
                    body.releaseIfPending(entry("old"))
                    nextBody.releaseIfPending(entry("new"))
                }
            }
        }
    }

    @Test fun removedActualBodyRejectsLateCompletionEvenWithNoOriginContext() = runBlocking {
        withTimeout(5_000) {
            val body = Completion<Entry>()
            val h = Harness(this)
            h.dictionaries += listOf("alias", "actual-body")
            val origin = hit("alias word").copy(dictionary = "alias", contextDictionary = null)
            val decoded = entry("followed word").copy(origin = origin, contentDictionary = "actual-body")
            h.read = { body.await() }
            val pending = h.navigation.open(origin)
            try {
                body.started.await()
                h.dictionaries -= "actual-body"
                h.navigation.libraryChanged()
                assertFalse(pending.isCancelled) // The reader has not returned its actual dependency yet.
                assertTrue(h.loading)
                body.succeed(decoded)
                pending.join()
                assertTrue(body.delivered)
                assertTrue(origin.isInstalled { it in h.dictionaries })
                assertFalse(decoded.isInstalled { it in h.dictionaries })
                assertNull(h.title)
                assertTrue(h.history.isEmpty())
                assertTrue(h.errors.isEmpty())
                assertFalse(h.loading)
            } finally {
                h.navigation.cancel()
                body.releaseIfPending(decoded)
            }
        }
    }

    @Test fun lookupReturningARemovedOriginOrContextNeverStartsItsRead() = runBlocking {
        withTimeout(5_000) {
            for (removed in listOf("origin", "context")) {
                val lookup = Completion<WordHit?>()
                val h = Harness(this)
                h.dictionaries += listOf("origin", "context")
                h.saved = { lookup.await() }
                val pending = h.navigation.openSaved(word("old", "origin"))
                try {
                    lookup.started.await()
                    h.dictionaries -= removed
                    h.navigation.libraryChanged()
                    assertNull(h.navigation.openInitialIfIdle())
                    lookup.succeed(hit("old").copy(dictionary = "origin", contextDictionary = "context"))
                    pending.join()
                    assertTrue(lookup.delivered)
                    assertTrue(h.reads.isEmpty())
                    assertTrue(h.history.isEmpty())
                    assertTrue(h.errors.isEmpty())
                    assertFalse(h.loading)
                } finally {
                    h.navigation.cancel()
                    lookup.releaseIfPending(null)
                }
            }
        }
    }

    @Test fun anAlreadyCancelledScopeDoesNotLeaveLoadingSet() = runBlocking {
        withTimeout(5_000) {
            val stopped = Job().apply { cancel() }
            val h = Harness(CoroutineScope(coroutineContext + stopped))
            val job = h.navigation.open(hit("never"))
            job.join()
            assertTrue(job.isCancelled)
            assertTrue(h.reads.isEmpty())
            assertTrue(h.errors.isEmpty())
            assertFalse(h.loading)
        }
    }

    @Test fun ambiguousLinkChoiceKeepsAllOwnersOriginalFragmentAndExactBackVisit() = runBlocking {
        withTimeout(5_000) {
            val from = hit("Gvangjcouh").copy(dictionary = "za", language = "Vahcuengh")
            val choices = mutableListOf(hit("Canton").copy(dictionary = "en", language = "English"),
                hit("Canton").copy(dictionary = "fr", language = "French"),
                hit("Canton").copy(dictionary = "nl", language = "Dutch"))
            val offered = CompletableDeferred<Pair<EntryLink, List<WordHit>>>()
            val answer = CompletableDeferred<WordHit?>()
            val h = Harness(this, choices = { _, _ -> choices }, choose = { action, hits ->
                offered.complete(action to hits); answer.await()
            })
            h.dictionaries += listOf("za", "en", "fr", "nl")
            h.navigation.open(from).join()
            val original = h.visits.currentId
            val action = EntryLink("Canton", "Noun#part")
            val pending = h.navigation.openLink(action, entry("Gvangjcouh"))
            val (observed, rows) = offered.await()
            assertSame(action, observed)
            assertEquals(listOf("English", "French", "Dutch"), rows.map { it.language })
            assertEquals(original, h.visits.currentId)
            assertEquals(listOf("Gvangjcouh"), h.history)
            assertTrue(h.visits.canGoBack)
            assertFalse(h.loading) // Waiting for a decision is not a read in progress.
            val selected = rows[1]
            choices.clear() // Resolver mutation cannot alter the offered immutable snapshot.
            answer.complete(selected)
            pending.join()
            assertEquals(selected, h.exactReads.last())
            assertSame(action, h.targetComponents)
            assertEquals(listOf("Gvangjcouh", "Canton"), h.history)
            assertTrue(h.navigation.goBack())
            while (h.loading) yield()
            assertEquals(from, h.restoredHit)
            assertEquals(original, h.visits.currentId)
            assertEquals(EntryLink(""), h.targetComponents)
            assertTrue(h.errors.isEmpty())
            assertFalse(h.navigation.goBack())
        }
    }

    @Test fun pendingLinkChoiceCancelsWithoutHistoryAndLateChoiceCannotReplaceNewIntent() = runBlocking {
        withTimeout(5_000) {
            for (mode in listOf("dismiss", "back", "supersede")) {
                val offered = CompletableDeferred<Unit>()
                val late = Completion<WordHit?>()
                val first = hit("Canton")
                val second = first.copy(dictionary = "other")
                val h = Harness(this, choices = { _, _ -> listOf(first, second) }, choose = { _, _ ->
                    offered.complete(Unit); late.await()
                })
                h.dictionaries += "other"
                h.navigation.open(hit("source")).join()
                val original = h.visits.currentId
                val pending = h.navigation.openLink(EntryLink("Canton#Noun"), entry("source"))
                try {
                    offered.await(); late.started.await()
                    when (mode) {
                        "dismiss" -> late.succeed(null)
                        "back" -> { assertTrue(h.navigation.goBack()); late.succeed(first) }
                        else -> { h.navigation.open(hit("new root")).join(); late.succeed(first) }
                    }
                    pending.join()
                    assertEquals(if (mode == "supersede") listOf("source", "new root") else listOf("source"), h.history)
                    if (mode != "supersede") assertEquals(original, h.visits.currentId)
                    assertTrue(h.errors.isEmpty())
                    assertFalse(h.visits.canGoBack)
                    assertFalse(h.loading)
                } finally { h.navigation.cancel(); late.releaseIfPending(null) }
            }
        }
    }

    @Test fun linkChoiceRejectsForgedRemovedAndDetachedResultsWithoutLosingOriginalVisit() = runBlocking {
        withTimeout(5_000) {
            for (mode in listOf("forged", "removed", "detached")) {
                val offered = CompletableDeferred<Unit>()
                val answer = CompletableDeferred<WordHit?>()
                val state = EntryNavigationState()
                val first = hit("Canton").copy(dictionary = "first")
                val second = first.copy(dictionary = "second")
                val h = Harness(this, state, choices = { _, _ -> listOf(first, second) }, choose = { _, _ ->
                    offered.complete(Unit); answer.await()
                })
                h.dictionaries += listOf("first", "second")
                h.navigation.open(hit("source")).join()
                val original = h.visits.currentId
                val pending = h.navigation.openLink(EntryLink("Canton", "Noun"), entry("source"))
                offered.await()
                if (mode == "removed") { h.dictionaries -= "first"; h.navigation.libraryChanged() }
                if (mode == "detached") Harness(this, state) // New controller owns committed state.
                answer.complete(if (mode == "forged") hit("forged") else first)
                pending.join()
                assertEquals(listOf("source"), h.history)
                assertEquals(original, state.snapshot().currentId)
                if (mode == "forged") assertEquals(listOf("This dictionary choice is no longer available."), h.errors)
                else assertTrue(h.errors.isEmpty())
                h.navigation.cancel()
            }
        }
    }
}
