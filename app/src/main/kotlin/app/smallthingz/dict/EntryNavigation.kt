package app.smallthingz.dict

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** Called on the UI scope: one intent owns lookup, decoding, publication and loading. */
internal class EntryNavigation(
    private val scope: CoroutineScope,
    private val read: suspend (WordHit) -> Entry,
    private val link: suspend (String, Entry) -> WordHit?,
    private val saved: suspend (SavedWord) -> WordHit?,
    private val random: suspend () -> WordHit?,
    private val initial: suspend () -> WordHit?,
    private val commit: (WordHit, Entry, String) -> Unit,
    private val loading: (Boolean) -> Unit,
    private val error: suspend (String) -> Unit,
    private val installed: (String) -> Boolean,
) {
    private data class Destination(val hit: WordHit, val target: String = "")
    private var generation: Any = Any()
    private var active: Job? = null
    private var pendingHit: WordHit? = null

    fun open(hit: WordHit): Job = begin { Destination(hit) }

    fun openLink(target: String, entry: Entry): Job = begin {
        val hit = link(target, entry)
            ?: throw IllegalStateException("This word is not in your installed dictionaries.")
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

    fun libraryChanged() {
        // An unresolved lookup still owns its intent. Check its hit when it returns.
        // Immutable IDs let unrelated additions/removals leave valid work untouched.
        if (pendingHit?.isInstalled(installed) == false) cancel()
    }

    fun cancel() {
        generation = Any()
        active?.cancel()
        active = null
        pendingHit = null
        loading(false)
    }

    fun interrupt(action: () -> Unit) {
        cancel()
        action()
    }

    private fun begin(resolve: suspend () -> Destination?): Job {
        val token = Any()
        generation = token
        active?.cancel()
        pendingHit = null
        loading(true)
        // Assign before starting: an immediate result must not leave a completed job as owner.
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                val destination = resolve() ?: return@launch
                currentCoroutineContext().ensureActive()
                if (generation !== token || !destination.hit.isInstalled(installed)) return@launch
                pendingHit = destination.hit
                val entry = read(destination.hit)
                currentCoroutineContext().ensureActive()
                if (generation === token && entry.isInstalled(installed)) {
                    commit(destination.hit, entry, destination.target)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (generation === token && currentCoroutineContext().isActive &&
                    pendingHit?.isInstalled(installed) != false) {
                    error(e.message ?: "Unable to read this word")
                }
            } finally {
                // A cancelled, non-cooperative predecessor cannot clear the next intent's spinner.
                if (generation === token) {
                    active = null
                    pendingHit = null
                    loading(false)
                }
            }
        }
        active = job
        if (!job.start() && job.isCancelled && generation === token) {
            active = null
            pendingHit = null
            loading(false)
        }
        return job
    }
}
