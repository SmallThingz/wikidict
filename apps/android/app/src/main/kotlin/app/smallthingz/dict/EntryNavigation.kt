package app.smallthingz.dict

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

internal data class EntryVisitState(
    val currentId: Long? = null,
    val entryKey: String? = null,
    val retainedIds: Set<Long> = emptySet(),
    val canGoBack: Boolean = false,
)

/** Committed metadata survives controller replacement; pending jobs never do. */
internal class EntryNavigationState {
    internal data class Visit(val id: Long, val hit: WordHit, val contentDictionary: String, val entryKey: String) {
        fun available(installed: (String) -> Boolean) = hit.isInstalled(installed) && installed(contentDictionary)
    }
    internal var current: Visit? = null
    internal val previous = mutableListOf<Visit>()
    internal var nextVisit = 0L
    private var owner: Any? = null
    internal fun attach(): Any = Any().also { owner = it }
    internal fun owns(token: Any) = owner === token

    internal fun snapshot(pending: Boolean = false) = EntryVisitState(current?.id, current?.entryKey,
        (previous.map { it.id } + listOfNotNull(current?.id)).toSet(),
        pending || previous.isNotEmpty())
}

/** Called on the UI scope: one intent owns lookup, decoding, publication and loading. */
internal class EntryNavigation(
    private val scope: CoroutineScope,
    private val read: suspend (WordHit) -> Entry,
    private val link: suspend (EntryLink, Entry) -> WordHit?,
    private val saved: suspend (SavedWord) -> WordHit?,
    private val random: suspend () -> WordHit?,
    private val initial: suspend () -> WordHit?,
    private val commit: (WordHit, Entry, EntryLink) -> Unit,
    private val loading: (Boolean) -> Unit,
    private val error: suspend (String) -> Unit,
    private val installed: (String) -> Boolean,
    private val restore: ((WordHit, Entry) -> Unit)? = null,
    private val visitsChanged: (EntryVisitState) -> Unit = {},
    private val state: EntryNavigationState = EntryNavigationState(),
    private val linkChoices: (suspend (EntryLink, Entry) -> List<WordHit>)? = null,
    private val chooseLink: suspend (EntryLink, List<WordHit>) -> WordHit? = { _, _ -> null },
) {
    private data class Destination(val hit: WordHit, val target: EntryLink = EntryLink(""))
    private val owner = state.attach()
    private enum class Intent { Root, Link, Back }
    private var current: EntryNavigationState.Visit?
        get() = state.current
        set(value) { state.current = value }
    private val previous get() = state.previous
    private var nextVisit: Long
        get() = state.nextVisit
        set(value) { state.nextVisit = value }
    private var generation: Any = Any()
    private var active: Job? = null
    private var pendingHit: WordHit? = null
    private var pendingBack = false

    fun open(hit: WordHit): Job = begin { Destination(hit) }

    fun openLink(target: EntryLink, entry: Entry): Job = begin(Intent.Link) {
        val choices = (linkChoices?.invoke(target, entry) ?: listOfNotNull(link(target, entry))).toList()
        currentCoroutineContext().ensureActive()
        if (!state.owns(owner)) return@begin null
        if (choices.isEmpty()) throw IllegalStateException("This word is not in your installed dictionaries.")
        val hit = choices.singleOrNull() ?: run {
            // The original Link intent remains pending; choosing is not a new root visit.
            loading(false)
            val selected = chooseLink(target, choices) ?: return@begin null
            currentCoroutineContext().ensureActive()
            if (!state.owns(owner)) return@begin null
            require(selected in choices) { "This dictionary choice is no longer available." }
            loading(true)
            selected
        }
        Destination(hit, target)
    }

    fun openSaved(word: SavedWord): Job = begin {
        val hit = saved(word) ?: throw IllegalStateException(
            if (word.dictionary == null) "Choose ${word.title} again from search."
            else "Install the dictionary for ${word.title}.",
        )
        Destination(hit)
    }

    fun openRandom(): Job = begin { random()?.let { Destination(it) } }
    fun openInitial(): Job = begin { initial()?.let { Destination(it) } }
    fun openInitialIfIdle(): Job? = if (active == null) openInitial() else null

    /** Pending work consumes Back first; no read may publish after its token is cancelled. */
    fun goBack(): Boolean {
        if (!state.owns(owner)) { cancel(); return false }
        if (active != null) { cancel(); return true }
        val visit = previous.lastOrNull() ?: return false
        begin(Intent.Back, visit) { Destination(visit.hit) }
        return true
    }

    private fun publishVisits() {
        if (state.owns(owner)) visitsChanged(state.snapshot(active != null))
    }

    fun libraryChanged() {
        if (!state.owns(owner)) return
        // An unresolved lookup still owns its intent. Check its hit when it returns.
        // Immutable IDs let unrelated additions/removals leave valid work untouched.
        if (pendingHit?.isInstalled(installed) == false) cancel()
        if (current?.available(installed) == false) {
            // Losing the displayed owner must not cancel a still-valid new lookup.
            // A Back reread, however, belongs to the path that is being discarded.
            if (pendingBack) cancel()
            current = null
            previous.clear()
        } else previous.removeAll { !it.available(installed) }
        publishVisits()
    }

    fun cancel() {
        generation = Any()
        active?.cancel()
        active = null
        pendingHit = null
        pendingBack = false
        loading(false)
        publishVisits()
    }

    fun interrupt(action: () -> Unit) {
        cancel()
        action()
    }

    private fun begin(intent: Intent = Intent.Root, returning: EntryNavigationState.Visit? = null, resolve: suspend () -> Destination?): Job {
        val token = Any()
        generation = token
        active?.cancel()
        pendingHit = null
        pendingBack = intent == Intent.Back
        loading(true)
        // Assign before starting: an immediate result must not leave a completed job as owner.
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                if (!state.owns(owner)) return@launch
                val destination = resolve() ?: return@launch
                currentCoroutineContext().ensureActive()
                if (generation !== token || !state.owns(owner) || !destination.hit.isInstalled(installed)) return@launch
                pendingHit = destination.hit
                val entry = read(destination.hit)
                currentCoroutineContext().ensureActive()
                if (generation === token && state.owns(owner) && entry.isInstalled(installed)) {
                    // A return is to the exact immutable hit/body owner, not a new title lookup.
                    if (intent == Intent.Back && (returning == null || previous.lastOrNull() != returning ||
                        entry.origin?.key != returning.hit.key || entry.contentDictionary != returning.contentDictionary ||
                        entry.key != returning.entryKey)) throw IllegalStateException("This previous word is no longer available.")
                    val visit = if (intent == Intent.Back) checkNotNull(returning) else
                        EntryNavigationState.Visit(++nextVisit, destination.hit, checkNotNull(entry.contentDictionary), entry.key)
                    when (intent) {
                        Intent.Root -> previous.clear()
                        Intent.Link -> current?.takeIf { it.available(installed) }?.let {
                            previous += it
                            if (previous.size > 32) previous.removeAt(0)
                        }
                        Intent.Back -> previous.removeAt(previous.lastIndex)
                    }
                    current = visit
                    publishVisits()
                    if (intent == Intent.Back && restore != null) restore.invoke(destination.hit, entry)
                    else commit(destination.hit, entry, destination.target)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (generation === token && state.owns(owner) && currentCoroutineContext().isActive &&
                    pendingHit?.isInstalled(installed) != false) {
                    loading(false)
                    error(e.message ?: "Unable to read this word")
                }
            } finally {
                // A cancelled, non-cooperative predecessor cannot clear the next intent's spinner.
                if (generation === token) {
                    active = null
                    pendingHit = null
                    pendingBack = false
                    loading(false)
                    publishVisits()
                }
            }
        }
        active = job
        publishVisits()
        if (!job.start() && job.isCancelled && generation === token) {
            active = null
            pendingHit = null
            pendingBack = false
            loading(false)
            publishVisits()
        }
        return job
    }
}
