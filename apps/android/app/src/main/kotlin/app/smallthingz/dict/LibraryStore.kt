package app.smallthingz.dict

import android.app.DownloadManager
import android.net.Uri
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import androidx.compose.runtime.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.*
import java.net.URI
import java.security.MessageDigest
import java.util.UUID

private val blobKinds = listOf("language", "thesaurus", "citations", "reconstruction", "rhymes", "sign_gloss", "supplemental", "alias")
internal fun blobKind(tag: Int): String = blobKinds.getOrNull(tag - 1) ?: error("Invalid blob kind")

// A failed commit may already have removed the process-local preference values.
// Keep the exact owned record until clearing is durable, even if restoration throws.
internal class DownloadClearOwner {
    private var pending: Map<String, Any?>? = null
    fun id(current: Long): Long {
        if (current >= 0) {
            if (pending?.get("downloadId") != current) pending = null
            return current
        }
        return pending?.get("downloadId") as? Long ?: -1L
    }
    fun clear(id: Long, lock: Any, current: () -> Long, snapshot: () -> Map<String, Any?>,
        retain: (Boolean) -> Unit, commit: () -> Boolean, restore: (Map<String, Any?>) -> Boolean) = synchronized(lock) {
        if (this.id(current()) != id) return@synchronized
        val saved = pending ?: snapshot()
        check(saved["downloadId"] == id)
        pending = saved
        retain(true)
        val message = "Could not confirm download removal. Saved state is uncertain; keep the app open and retry cancellation."
        val failure = try {
            if (commit()) { pending = null; retain(current() >= 0); return@synchronized }
            IOException(message)
        } catch (original: Exception) { IOException(message, original) }
        if (this.id(current()) == id) {
            try {
                if (!restore(saved)) failure.addSuppressed(IOException("Could not persist restored download metadata; saved state is uncertain."))
            } catch (restoration: Exception) { failure.addSuppressed(restoration) }
        }
        retain(this.id(current()) >= 0)
        throw failure
    }
}

// Android's sqlite3_bind_text16 interprets an initial U+FEFF as a byte-order mark.
// Prefix query parameters and remove only that sentinel on the constant SQL side.
private fun sqlText(value: String) = "x$value"

data class DictionaryInfo(val id: String, val language: String, val code: String, val kind: String, val count: Int, val bytes: Long, val edition: String = "")
data class WordHit(val dictionary: String, val title: String, val language: String, val kind: String, val offset: Long, val length: Int,
    val recordKey: String = title, val contextDictionary: String? = null, val edition: String = "") {
    val key get() = "$dictionary\u0000${contextDictionary.orEmpty()}\u0000$recordKey"
}
data class CatalogItem(val url: String, val label: String, val bytes: Long? = null, val sha256: String? = null)
object Catalog {
    const val DEFAULT = "https://github.com/SmallThingz/wikidict/releases/latest/download/dictionaries.list"
    const val DEBUG_FIXTURE = "asset://debug-dictionaries.list"
    fun parse(text: String, debug: Boolean = false): List<CatalogItem> {
        require(text.toByteArray().size <= 2*1024*1024) { "Catalogue is too large" }
        return text.lineSequence().map(String::trim).filter { it.isNotEmpty() && !it.startsWith('#') }.map { line ->
            val fields = line.split('\t'); require(fields.size in 1..4) { "Invalid catalogue row" }
            val uri = URI(fields[0]); require(uri.scheme == "https" || (debug && uri.scheme == "asset")) { "Catalogue links must use HTTPS" }
            require(uri.host != null && uri.userInfo == null && uri.fragment == null)
            val size = fields.getOrNull(2)?.takeIf { it.isNotBlank() }?.toLong()?.also { require(it > 0) }
            val hash = fields.getOrNull(3)?.takeIf { it.isNotBlank() }?.lowercase()?.also { require(it.matches(Regex("[a-f0-9]{64}"))) }
            CatalogItem(fields[0], fields.getOrNull(1)?.takeIf { it.isNotBlank() } ?: uri.path.substringAfterLast('/').removeSuffix(".wikblb"), size, hash)
        }.take(10001).toList().also { require(it.size <= 10000); require(it.map { x -> x.url }.distinct().size == it.size) }
    }
}
internal suspend fun hashImportedDictionary(input: InputStream): String {
    val digest = MessageDigest.getInstance("SHA-256")
    val buffer = ByteArray(256*1024)
    while (true) {
        currentCoroutineContext().ensureActive()
        val count = input.read(buffer)
        if (count < 0) break
        digest.update(buffer, 0, count)
    }
    currentCoroutineContext().ensureActive()
    return digest.digest().joinToString("") { "%02x".format(it) }
}

// A watcher owns the ID it started with, not whichever download is current later.
internal fun removeOwnedDownload(id: Long, lock: Any, currentId: () -> Long, remove: (Long) -> Unit, clear: () -> Unit) {
    remove(id)
    synchronized(lock) { if (currentId() == id) clear() }
}

internal fun failOwnedDownload(failure: Exception, cleanup: () -> Unit): Nothing {
    if (failure is CancellationException) throw failure
    try { cleanup() }
    catch (cancelled: CancellationException) { throw cancelled }
    catch (cleanupFailure: Exception) { if (cleanupFailure !== failure) failure.addSuppressed(cleanupFailure) }
    throw failure
}

internal fun cancelOwnedDownload(remove: () -> Unit, cancelOperation: () -> Unit,
    cancelOnRemovalFailure: Boolean = false): Exception? {
    var failure: Exception? = null
    try { remove() }
    catch (cancelled: CancellationException) { throw cancelled }
    catch (removalFailure: Exception) { failure = removalFailure }
    if (failure == null || cancelOnRemovalFailure) {
        try { cancelOperation() }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (cancelFailure: Exception) {
            if (failure == null) failure = cancelFailure
            else if (failure !== cancelFailure) failure.addSuppressed(cancelFailure)
        }
    }
    return failure
}

// A failed disk commit still leaves SharedPreferences ownership in memory.
// Compensate the exact new ID; a failed removal must keep Cancel available.
internal fun enqueueOwnedDownload(lock: Any, enqueue: () -> Long, commit: (Long) -> Boolean, remove: (Long) -> Unit): Long {
    val (id, committed) = synchronized(lock) {
        val id = enqueue()
        id to commit(id)
    }
    if (committed) return id
    try { remove(id) }
    catch (cancelled: CancellationException) { throw cancelled }
    catch (failure: Exception) {
        throw IOException("Could not save the download and cancellation failed. Keep the app open and use Cancel to retry.", failure)
    }
    throw IOException("Could not save the download. The download was cancelled.")
}

internal fun committedDictionaryRegistration(db: SQLiteDatabase, id: String): Boolean? {
    if (db.inTransaction()) return null
    // A fresh writer transaction cannot succeed while an earlier native write
    // transaction remains unresolved, even if the Java stack was already cleared.
    db.beginTransaction()
    return try {
        db.rawQuery("SELECT id FROM dictionaries WHERE id=?", arrayOf(id)).use { it.moveToFirst() }
    } finally { db.endTransaction() }
}

// An endTransaction exception does not establish whether COMMIT succeeded.
// registered must observe committed state; null means the outcome is unresolved.
internal inline fun finishDictionaryInstall(
    failure: Throwable?, placedFile: File?, endTransaction: () -> Unit,
    registered: () -> Boolean?, refresh: () -> Unit
) {
    var primary = failure
    try { endTransaction() }
    catch (endFailure: Exception) {
        if (primary == null) primary = endFailure
        else if (primary !== endFailure) primary.addSuppressed(endFailure)
    }
    val error = primary
    if (error == null) {
        refresh()
        return
    }
    if (error is Error) return // Preserve fatal body failures without recovery work.
    if (placedFile != null) {
        try {
            when (registered()) {
                false -> if (!placedFile.delete() && placedFile.exists()) {
                    throw IOException("Cannot remove unregistered dictionary")
                }
                true -> refresh()
                null -> Unit
            }
        } catch (cleanupFailure: Exception) {
            if (cleanupFailure !== error) error.addSuppressed(cleanupFailure)
        }
    }
    if (failure == null) throw error
}

// A release error may follow a committed deletion. Reconcile before changing its
// payload, and publish confirmed removal even when payload cleanup also fails.
internal inline fun finishDictionaryRemoval(
    failure: Throwable?, endTransaction: () -> Unit, registered: () -> Boolean?,
    removeFile: () -> Unit, refresh: () -> Unit
) {
    var primary = failure
    try { endTransaction() }
    catch (endFailure: Exception) {
        if (primary == null) primary = endFailure
        else if (primary !== endFailure) primary.addSuppressed(endFailure)
    }
    if (primary is Error) return
    val removed = if (primary == null) true else try { registered() == false }
        catch (queryFailure: Exception) {
            if (primary !== queryFailure) primary.addSuppressed(queryFailure)
            false
        }
    if (removed) {
        try { removeFile() }
        catch (cleanupFailure: Exception) {
            if (primary == null) primary = cleanupFailure
            else if (primary !== cleanupFailure) primary.addSuppressed(cleanupFailure)
        }
        try { refresh() }
        catch (refreshFailure: Exception) {
            if (primary == null) primary = refreshFailure
            else if (primary !== refreshFailure) primary.addSuppressed(refreshFailure)
        }
    }
    if (failure == null) primary?.let { throw it }
}

// Queued operations must not replace the job that currently owns the library.
internal class LibraryOperationOwner(private val mutex: Mutex, private val ownershipLock: Any = Any()) {
    // One coherent capture owns both the job and its operation epoch. Keep the
    // epoch after completion so an old Cancel cannot overwrite a newer result.
    internal class Snapshot internal constructor(val job: Job?, internal val epoch: Any,
        val ownedDownloadId: Long? = null, val cancellationRequested: Boolean = false)
    @Volatile private var state = Snapshot(null, Any())
    val active: Job? get() = state.job
    fun capture(): Snapshot = state
    // Record intent while the caller captures the persisted ID under this same lock.
    // Cleanup remains asynchronous; an action must not enqueue behind that request.
    fun requestCancellation(): Snapshot = synchronized(ownershipLock) {
        Snapshot(state.job, state.epoch, state.ownedDownloadId, true).also { state = it }
    }
    fun checkEnqueue(owner: Snapshot) = synchronized(ownershipLock) {
        val job = owner.job ?: throw CancellationException("No active download operation")
        if (state.job !== job || state.epoch !== owner.epoch || state.cancellationRequested)
            throw CancellationException("Download operation no longer accepts enqueue")
        job.ensureActive()
    }
    // Enqueue publishes its ID under the same lock as persisted download ownership.
    // A late callback from a previous job cannot tag the current operation.
    fun claimDownload(owner: Snapshot, id: Long) = synchronized(ownershipLock) {
        if (id >= 0 && owner.job != null && state.job === owner.job && state.epoch === owner.epoch)
            state = Snapshot(owner.job, owner.epoch, id, state.cancellationRequested)
    }
    fun cancelCaptured(captured: Snapshot, id: Long, remove: () -> Unit): Exception? =
        cancelOwnedDownload(remove, { captured.job?.cancel() }, captured.ownedDownloadId != id)
    fun publishIfCurrent(captured: Snapshot, publish: () -> Unit): Unit = synchronized(ownershipLock) {
        if (state.epoch === captured.epoch) publish()
    }

    suspend fun run(
        start: suspend () -> Unit = {},
        finish: suspend () -> Unit = {},
        ownedDownloadId: () -> Long? = { null },
        action: suspend () -> Unit,
    ) = mutex.withLock {
        val owner = currentCoroutineContext().job
        val owned = synchronized(ownershipLock) { Snapshot(owner, Any(), ownedDownloadId()).also { state = it } }
        try {
            // Publication can complete before cancellation wins its return dispatch.
            // Own cleanup before entering that first cancellable boundary.
            try { start(); action() }
            finally { finish() }
        } finally { synchronized(ownershipLock) {
            if (state.epoch === owned.epoch) state = Snapshot(null, owned.epoch)
        } }
    }
}

// A committed mutation must become visible before its cancelled owner releases the mutex.
internal suspend fun publishLibrarySnapshot(db: SQLiteDatabase, publish: (List<DictionaryInfo>) -> Unit) {
    val values = db.rawQuery("SELECT * FROM dictionaries ORDER BY language", null).use { c -> buildList {
        while (c.moveToNext()) add(DictionaryInfo(c.getString(0), c.getString(1), c.getString(2), c.getString(3), c.getInt(4), c.getLong(5), c.getString(6)))
    } }
    withContext(NonCancellable + Dispatchers.Main) { publish(values) }
    currentCoroutineContext().ensureActive()
}

// Entry.copy rebuilds reading rows and abbreviations, so origin binding stays on IO too.
internal suspend fun readEntryOnIo(hit: WordHit, resolve: () -> Entry): Entry =
    withContext(Dispatchers.IO) {
        val entry = resolve()
        currentCoroutineContext().ensureActive()
        entry.copy(origin = hit)
    }

class LibraryStore private constructor(private val context: Context) {
    companion object {
        @Volatile private var instance: LibraryStore? = null
        fun get(context: Context) = instance ?: synchronized(this) { instance ?: LibraryStore(context.applicationContext).also { instance = it } }
    }
    private val directory = File(context.filesDir, "dictionaries").apply { mkdirs() }
    private val helper = LibraryDatabase(context).apply { setWriteAheadLoggingEnabled(true) }
    private val mutex = Mutex()
    private val downloadLock = Any()
    private val operations = LibraryOperationOwner(mutex, downloadLock)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    var dictionaries by mutableStateOf<List<DictionaryInfo>>(emptyList()); private set
    var busy by mutableStateOf<String?>(null); private set
    var progress by mutableFloatStateOf(0f); private set
    var transferDetail by mutableStateOf<String?>(null); private set
    private val failures = LibraryFailureState()
    val initializationError get() = failures.initializationError
    var error: String?
        get() = failures.operationError
        private set(value) { failures.operationError = value }
    var revision by mutableIntStateOf(0); private set
    var catalog by mutableStateOf<List<CatalogItem>>(emptyList()); private set
    private val prefs = context.getSharedPreferences("library", Context.MODE_PRIVATE)
    private val downloadRecordKeys = listOf("downloadId", "downloadUrl", "downloadLabel", "downloadBytes", "downloadHash")
    private val downloadClear = DownloadClearOwner()
    var hasRetainedDownload by mutableStateOf(downloadId() >= 0); private set
    var sources by mutableStateOf(prefs.getStringSet("sources", if (BuildConfig.DEBUG) setOf(Catalog.DEBUG_FIXTURE) else emptySet())!!.toList()); private set
    init { scope.launch {
        val opened = mutex.withLock {
            failures.initialize(open = {
                val installed=helper.readableDatabase.rawQuery("SELECT id FROM dictionaries",null).use{c->buildSet{while(c.moveToNext())add(c.getString(0)+".wikblb")}}
                directory.listFiles()?.filter{it.extension=="part" || (it.extension=="wikblb" && it.name !in installed)}?.forEach{it.delete()}
                refresh()
            }, publishFailure = { change -> withContext(Dispatchers.Main) { change() } })
        }
        if (opened) resumeDownload()
    } }
    private suspend fun refresh() = publishLibrarySnapshot(helper.readableDatabase) { values ->
        dictionaries = values; revision++
    }
    fun addSource(url: String) {
        val uri = URI(url.trim()); require((BuildConfig.DEBUG && uri.toString() == Catalog.DEBUG_FIXTURE) ||
            (uri.scheme == "https" && uri.host != null && uri.userInfo == null)) { "Use an HTTPS catalogue URL" }
        sources = (sources + uri.toString()).distinct(); prefs.edit().putStringSet("sources", sources.toSet()).apply()
    }
    fun removeSource(url: String) { sources = sources - url; prefs.edit().putStringSet("sources", sources.toSet()).apply(); refreshCatalogs() }
    fun cancel() {
        val (id, operation) = synchronized(downloadLock) { downloadId() to operations.requestCancellation() }
        scope.launch {
            val failure = operations.cancelCaptured(operation, id) { if (id >= 0) removeDownload(id) }
            withContext(Dispatchers.Main) { operations.publishIfCurrent(operation) {
                error = failure?.let { "Could not cancel download: ${it.message ?: "Try again"}" }
            } }
        }
    }
    private val manager get() = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    private fun downloadId() = synchronized(downloadLock) { downloadClear.id(prefs.getLong("downloadId", -1)) }
    private fun restoreDownloadRecord(record: Map<String, Any?>): Boolean {
        val edit = prefs.edit()
        downloadRecordKeys.forEach { edit.remove(it) }
        record.forEach { (key, value) -> when (value) {
            is String -> edit.putString(key, value)
            is Long -> edit.putLong(key, value)
            is Int -> edit.putInt(key, value)
            is Boolean -> edit.putBoolean(key, value)
            is Float -> edit.putFloat(key, value)
            is Set<*> -> {
                if (value.any { it !is String }) throw IOException("Could not restore saved download metadata type")
                edit.putStringSet(key, value.map { it as String }.toSet())
            }
            else -> throw IOException("Could not restore saved download metadata type")
        } }
        return edit.commit()
    }
    private fun clearDownload(id: Long) = downloadClear.clear(id, downloadLock,
        { prefs.getLong("downloadId", -1) },
        { prefs.all.filterKeys { it in downloadRecordKeys }.mapValues { (_, value) -> if (value is Set<*>) value.toSet() else value } },
        { hasRetainedDownload = it },
        { prefs.edit().apply { downloadRecordKeys.forEach { remove(it) } }.commit() },
        ::restoreDownloadRecord)
    private fun removeDownload(id: Long) = removeOwnedDownload(id, downloadLock,
        { downloadId() }, { manager.remove(it) }, { clearDownload(id) })
    private fun resumeDownload() {
        if (downloadId() >= 0) {
            val item = CatalogItem(prefs.getString("downloadUrl", "")!!, prefs.getString("downloadLabel", "Dictionary")!!,
                prefs.getLong("downloadBytes", -1).takeIf { it > 0 }, prefs.getString("downloadHash", null))
            operation("Downloading ${item.label}", ownsDownload = true) { watchDownload(item) }
        }
    }
    private suspend fun watchDownload(item: CatalogItem) {
        val id = downloadId()
        try { while (true) {
            currentCoroutineContext().ensureActive()
            val state = manager.query(DownloadManager.Query().setFilterById(id)).use { c ->
                if (!c.moveToFirst()) { clearDownload(id); error("Download was removed. Tap download to try again.") }
                longArrayOf(c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)),
                    c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)),
                    c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)),
                    c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)))
            }
            val total = item.bytes ?: state[2]
            require(state[1] <= 32L*1024*1024*1024 && (item.bytes == null || state[1] <= item.bytes)) { "Invalid download size" }
            withContext(Dispatchers.Main) {
                progress = if (total > 0) (state[1].toFloat()/total).coerceIn(0f,1f) else 0f
                transferDetail = "${android.text.format.Formatter.formatShortFileSize(context,state[1])}" +
                    (if(total>0) " / ${android.text.format.Formatter.formatShortFileSize(context,total)} · ${(progress*100).toInt()}%" else "") +
                    (if(state[0].toInt()==DownloadManager.STATUS_PAUSED) " · Waiting for network / retry" else "")
            }
            when (state[0].toInt()) {
                DownloadManager.STATUS_SUCCESSFUL -> {
                    val temp = File(directory,"${UUID.randomUUID()}.part")
                    try {
                        withContext(Dispatchers.Main) { busy = "Verifying ${item.label}"; transferDetail = null; progress = 0f }
                        val digest = MessageDigest.getInstance("SHA-256")
                        var size = 0L
                        manager.openDownloadedFile(id).use { descriptor ->
                            android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
                                temp.outputStream().buffered(256*1024).use { out ->
                                    val buffer=ByteArray(256*1024)
                                    while(true) { currentCoroutineContext().ensureActive(); val n=input.read(buffer); if(n<0)break
                                        size+=n; require(size<=32L*1024*1024*1024); out.write(buffer,0,n); digest.update(buffer,0,n) }
                                }
                            }
                        }
                        val hash=digest.digest().joinToString(""){"%02x".format(it)}
                        require(item.bytes==null || size==item.bytes) { "Incomplete download" }
                        require(item.sha256==null || hash==item.sha256) { "Dictionary checksum does not match" }
                        withContext(Dispatchers.Main) { busy="Indexing ${item.label}" }
                        install(temp,hash,URI(item.url).path.substringAfterLast('/'))
                        removeDownload(id)
                    } finally { temp.delete() }
                    return
                }
                DownloadManager.STATUS_FAILED -> { removeDownload(id); error("Download failed (${state[3]}). Tap download to retry.") }
            }
            delay(400)
        } } catch (e: CancellationException) { throw e }
        catch (e: Exception) { failOwnedDownload(e) { removeDownload(id) } }
    }
    private fun operation(label: String, ownsDownload: Boolean = false, action: suspend () -> Unit): Job = scope.launch {
        operations.run(
            start = { withContext(Dispatchers.Main) { busy = label; error = null; progress = 0f; transferDetail = null } },
            finish = { withContext(NonCancellable + Dispatchers.Main) { busy = null; transferDetail = null } },
            ownedDownloadId = { if (ownsDownload) downloadId().takeIf { it >= 0 } else null },
        ) {
            try { action() } catch (e: CancellationException) { throw e } catch (e: Exception) {
                withContext(Dispatchers.Main) { error = e.message ?: "Could not complete this operation" }
            }
        }
    }
    fun refreshCatalogs() = operation("Reading catalogues") {
        val entries = ArrayList<CatalogItem>()
        val failures = ArrayList<String>()
        for(source in sources.toList()) {
            try {
                entries += if(BuildConfig.DEBUG && (source == Catalog.DEBUG_FIXTURE || source == Catalog.DEFAULT))
                    context.assets.open("debug-dictionaries.list").use { Catalog.parse(it.bufferedReader().readText(),true) }
                else Catalog.parse(Network.read(source,2*1024*1024).decodeToString(throwOnInvalidSequence=true))
            } catch(e:CancellationException) { throw e }
            catch(e:Exception) { failures += "${URI(source).host}: ${e.message ?: "Unavailable"}" }
        }
        withContext(Dispatchers.Main) {
            catalog=entries.distinctBy{it.url}
            error=failures.takeIf{it.isNotEmpty()}?.joinToString("\n")
        }
    }
    fun download(item: CatalogItem) = operation("Downloading ${item.label}", ownsDownload = !item.url.startsWith("asset://")) {
        if (!item.url.startsWith("asset://")) {
            require(URI(item.url).let { it.scheme == "https" && it.host != null && it.userInfo == null })
            require(item.bytes == null || item.bytes in 1..32L*1024*1024*1024) { "Dictionary is too large" }
            val existing = downloadId()
            if (existing >= 0 && prefs.getString("downloadUrl", null) != item.url) {
                error("Finish or cancel the current download first")
            }
            if (existing < 0) {
                val request = DownloadManager.Request(Uri.parse(item.url)).setTitle(item.label)
                    .setDescription("Wikidict dictionary")
                    .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                    .setDestinationInExternalFilesDir(context, "downloads", "${UUID.randomUUID()}.wikblb")
                val owner = operations.capture()
                enqueueOwnedDownload(downloadLock, {
                    operations.checkEnqueue(owner)
                    manager.enqueue(request)
                }, { id ->
                    operations.claimDownload(owner, id)
                    val committed = prefs.edit().putLong("downloadId",id).putString("downloadUrl",item.url).putString("downloadLabel",item.label)
                        .putLong("downloadBytes",item.bytes ?: -1).putString("downloadHash",item.sha256).commit()
                    hasRetainedDownload = true
                    committed
                }, { removeDownload(it) })
            }
            watchDownload(item)
            return@operation
        }
        val temp = File(directory, "${UUID.randomUUID()}.part")
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            var size = 0L
            val max = minOf(directory.usableSpace - 32*1024*1024, 32L*1024*1024*1024)
            val input = if (BuildConfig.DEBUG && item.url.startsWith("asset://")) context.assets.open(item.url.removePrefix("asset://")) else Network.open(item.url)
            input.use { source -> temp.outputStream().buffered(256*1024).use { out ->
                val buffer = ByteArray(256*1024); var update = 0L
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val n = source.read(buffer); if (n < 0) break
                    size += n; require(size <= max && (item.bytes == null || size <= item.bytes)) { "Insufficient space or invalid download size" }
                    out.write(buffer, 0, n); digest.update(buffer, 0, n)
                    if (size-update > 1024*1024) { update = size; withContext(Dispatchers.Main) { progress = item.bytes?.let { size.toFloat()/it } ?: 0f } }
                }
            } }
            val hash = digest.digest().joinToString("") { "%02x".format(it) }
            require(item.bytes == null || item.bytes == size) { "Incomplete download" }
            require(item.sha256 == null || item.sha256 == hash) { "Dictionary checksum does not match" }
            withContext(Dispatchers.Main) { busy = "Indexing ${item.label}" }
            install(temp, hash, URI(item.url).path.orEmpty().substringAfterLast('/'))
        } finally { temp.delete() }
    }
    fun importFile(name: () -> String = { "" }, input: () -> InputStream) = operation("Importing dictionary") {
        val temp = File(directory, "${UUID.randomUUID()}.part")
        try {
            coroutineScope {
                // Acquire only while this operation owns the mutex; keep the resource in
                // this scope even if cancellation arrives while the provider opens it.
                val source = input()
                var reader: Deferred<Unit>? = null
                var failure: Throwable? = null
                try {
                    reader = async(Dispatchers.IO) {
                        try {
                            temp.outputStream().use { out ->
                                val buffer = ByteArray(256*1024); var total = 0L; val max = directory.usableSpace - 32*1024*1024
                                while (true) { currentCoroutineContext().ensureActive(); val n = source.read(buffer); if (n < 0) break; total += n; require(total <= max) { "Not enough space to import this dictionary" }; out.write(buffer,0,n) }
                            }
                        } catch (readFailure: IOException) {
                            // Closing our provider FD wakes a blocked read with an I/O
                            // error. Preserve the user's cancellation in that case.
                            currentCoroutineContext().ensureActive()
                            throw readFailure
                        }
                    }
                    reader.await()
                } catch (error: Throwable) {
                    failure = error
                    throw error
                } finally {
                    // This must run inside coroutineScope, before it waits for children.
                    // The owned Android resolver stream signals blocked FD reads on close.
                    withContext(NonCancellable + Dispatchers.IO) {
                        try { source.close() }
                        catch (closeFailure: Throwable) {
                            val primary = failure
                            if (primary == null) throw closeFailure
                            if (closeFailure !== primary) primary.addSuppressed(closeFailure)
                        } finally { reader?.cancelAndJoin() }
                    }
                }
            }
            val hash = temp.inputStream().use { hashImportedDictionary(it) }
            install(temp, hash, name())
        } finally { temp.delete() }
    }
    private suspend fun install(temp: File, hash: String, filename: String) {
        val db = helper.writableDatabase
        val edition = dictionaryEdition(filename)
        val id = if (edition.isEmpty()) hash else "$hash-$edition"
        val alreadyInstalled = db.rawQuery("SELECT id FROM dictionaries WHERE id=?", arrayOf(id)).use { it.moveToFirst() }
        var count = 0; var language = ""; var code = ""; var kind = ""
        val final = File(directory, "$id.wikblb")
        var placedFile = false
        var failure: Throwable? = null
        db.beginTransaction()
        try {
            BlobSource(temp).use { source ->
            CountingInput(source.stream().buffered(256*1024)).use { input ->
                require(input.bytes(8).contentEquals("WIKBLB08".toByteArray())) { "Choose a WIKBLB08 dictionary" }
                kind = blobKind(input.read())
                if (kind == "language") { code = input.nul(); language = input.nul(); require(language.isNotBlank()) } else language = kind.replace('_',' ')
                validateDictionaryFilename(filename,kind,language)
                if (alreadyInstalled && final.isFile) return
                var previous: ByteArray? = null
                val statement = if (alreadyInstalled) null else db.compileStatement("INSERT INTO words VALUES(?,CAST(? AS TEXT),CAST(? AS TEXT),?,?,CAST(? AS TEXT),?)")
                statement.use {
                    while (input.position < source.length) {
                        currentCoroutineContext().ensureActive()
                        val title = input.nul(); require(title.isNotEmpty())
                        val raw = title.toByteArray(); previous?.let { require(compareUtf8(it,raw) < 0) { "Dictionary titles are not sorted" } }; previous = raw
                        val length = input.varuint(); require(length in 4..128L*1024*1024 && length <= source.length-input.position) { "Invalid record size" }
                        val offset = input.position
                        val alias = if (kind == "alias") AliasDecoder.decode(input.bytes(length.toInt()), title) else null
                        if (alias == null) {
                            // Validate the same complete record the reader will consume,
                            // before publishing either its rows or backing file.
                            BlobDecoder.decode(input.bytes(length.toInt()), title, kind,
                                if (kind == "language") language else null, code)
                        }
                        val lookup = alias?.sourceKey ?: title
                        if (statement != null) {
                            statement.bindString(1,id); statement.bindBlob(2,lookup.toByteArray(Charsets.UTF_8)); statement.bindBlob(3,foldSearchKey(lookup).toByteArray(Charsets.UTF_8)); statement.bindLong(4,offset); statement.bindLong(5,length)
                            statement.bindBlob(6,title.toByteArray(Charsets.UTF_8)); statement.bindString(7,alias?.sourceKind ?: kind); statement.executeInsert()
                        }
                        count++
                    }
                }
                require(input.read() == -1) { "Trailing dictionary data" }
            }
            }
            require(count > 0 || kind != "language") { "Dictionary has no entries" }
            currentCoroutineContext().ensureActive()
            // The ID hashes the complete staged bytes. A missing payload may be
            // restored after full validation without replacing its registered rows.
            if (alreadyInstalled) require(!final.exists()) { "Dictionary file changed during repair; try importing again" }
            require(temp.renameTo(final)) { "Cannot install dictionary" }
            placedFile = true
            if (!alreadyInstalled) {
            db.execSQL("INSERT INTO dictionaries VALUES(?,CAST(? AS TEXT),CAST(? AS TEXT),?,?,?,?)", arrayOf<Any>(id,language.toByteArray(Charsets.UTF_8),code.toByteArray(Charsets.UTF_8),kind,count,final.length(),edition))
            if (edition.isNotEmpty()) {
                val collision = db.rawQuery("""SELECT 1 FROM words a JOIN dictionaries ad ON ad.id=a.dictionary
                    JOIN dictionaries d ON d.edition=ad.edition AND d.kind=a.source_kind
                    JOIN words w ON w.dictionary=d.id AND w.title=a.title
                    WHERE ad.kind='alias' AND ad.edition=? LIMIT 1""", arrayOf(edition)).use { it.moveToFirst() }
                require(!collision) { "Redirect collides with a definition in this edition" }
            }
            }
            db.setTransactionSuccessful()
        } catch (e: Throwable) {
            failure = e
            throw e
        } finally {
            finishDictionaryInstall(
                failure, final.takeIf { placedFile }, { db.endTransaction() },
                registered = { committedDictionaryRegistration(db, id) },
                refresh = { refresh() }
            )
        }
    }
    suspend fun search(query: String, limit: Int = 80): List<WordHit> = withContext(Dispatchers.IO) {
        val q = foldSearchKey(query.trim())
        val upper = searchPrefixUpperBound(q)
        val range = if (upper == null) "normalized >= substr(?,2)"
            else "normalized >= substr(?,2) AND normalized < substr(?,2)"
        val count = limit.coerceIn(1,500).toString()
        val arguments = if (upper == null) arrayOf(sqlText(q), count)
            else arrayOf(sqlText(q), sqlText(upper), count)
        helper.readableDatabase.rawQuery("SELECT $hitColumns FROM word_choices WHERE $range ORDER BY normalized,title,language,dictionary LIMIT ?", arguments).use { c -> buildList {
            while(c.moveToNext()) add(hit(c))
        } }
    }
    suspend fun random(): WordHit? = withContext(Dispatchers.IO) {
        val choices=dictionaries.toList(); val total=choices.sumOf{it.count.toLong()}
        if(total==0L) return@withContext null
        var pick=kotlin.random.Random.nextLong(total)
        val dictionary=choices.first { if(pick<it.count) true else {pick-=it.count;false} }
        val db=helper.readableDatabase
        val first=db.rawQuery("SELECT MIN(rowid) FROM words WHERE dictionary=?",arrayOf(dictionary.id)).use{it.moveToFirst();it.getLong(0)}
        db.rawQuery("SELECT $hitColumns FROM word_choices WHERE wordid=? AND dictionary=? ORDER BY language LIMIT 1",arrayOf((first+pick).toString(),dictionary.id)).use{c ->
            if(c.moveToFirst()) hit(c) else null
        }
    }
    suspend fun exact(title: String, language: String? = null, edition: String? = null): WordHit? = withContext(Dispatchers.IO) {
        helper.readableDatabase.rawQuery("SELECT $hitColumns FROM word_choices WHERE normalized=substr(?,2) AND (?='0' OR edition=?) ORDER BY CASE WHEN language=substr(?,2) THEN 0 ELSE 1 END, CASE WHEN title=substr(?,2) THEN 0 ELSE 1 END, dictionary LIMIT 1",arrayOf(sqlText(foldSearchKey(title)),if(edition==null) "0" else "1",edition.orEmpty(),sqlText(language.orEmpty()),sqlText(title))).use{c ->
            if(c.moveToFirst()) hit(c) else null
        }
    }
    private val hitColumns = "dictionary,title,language,kind,payload,length,record_key,context_dictionary,edition"
    private fun hit(c: Cursor) = WordHit(c.getString(0),c.getString(1),c.getString(2),c.getString(3),c.getLong(4),c.getInt(5),c.getString(6),if(c.isNull(7)) null else c.getString(7),c.getString(8))
    private fun legacySelection(title: String, language: String?, kind: String?, edition: String): WordHit? {
        // Old records did not retain a dictionary ID. Preserve their recorded context;
        // an ambiguous match cannot establish which source the user had selected.
        return helper.readableDatabase.rawQuery("SELECT $hitColumns FROM word_choices WHERE normalized=substr(?,2) AND title=substr(?,2) AND edition=? AND (?='' OR kind=?) AND (?='0' OR language=substr(?,2)) LIMIT 2",
            arrayOf(sqlText(foldSearchKey(title)),sqlText(title),edition,kind.orEmpty(),kind.orEmpty(),if(language==null) "0" else "1",sqlText(language.orEmpty()))).use { c ->
            if (!c.moveToFirst()) null else hit(c).takeUnless { c.moveToNext() }
        }
    }
    suspend fun lastWord(): WordHit? = withContext(Dispatchers.IO) {
        val savedDictionary = prefs.getString("lastDictionary",null)
        if (savedDictionary != null) return@withContext helper.readableDatabase.rawQuery("SELECT $hitColumns FROM word_choices WHERE dictionary=? AND record_key=substr(?,2) AND COALESCE(context_dictionary,'')=? LIMIT 1",
            arrayOf(savedDictionary,sqlText(prefs.getString("lastRecordKey",null).orEmpty()),prefs.getString("lastContextDictionary",null).orEmpty())).use { c -> if(c.moveToFirst()) hit(c) else null }
        prefs.getString("lastTitle",null)?.let { legacySelection(it,prefs.getString("lastLanguage",null),null,prefs.getString("lastEdition",null).orEmpty()) }
    }
    private fun payload(hit: WordHit): ByteArray = BlobSource(File(directory,"${hit.dictionary}.wikblb")).use { it.read(hit.offset,hit.length) }
    private fun plain(hit: WordHit): Entry {
        val dictionary = dictionaries.firstOrNull { it.id == hit.dictionary } ?: error("Dictionary was removed")
        return (if(dictionary.kind == "alias") AliasDecoder.decode(payload(hit),hit.recordKey).entry()
            else BlobDecoder.decode(payload(hit),hit.title,hit.kind,if(hit.kind=="language")hit.language else null,dictionary.code)).copy(edition=dictionary.edition,contentDictionary=dictionary.id)
    }
    suspend fun read(hit: WordHit): Entry = readEntryOnIo(hit) {
        val dictionary = dictionaries.firstOrNull { it.id == hit.dictionary } ?: error("Dictionary was removed")
        if (dictionary.kind != "alias") return@readEntryOnIo plain(hit)
        val alias = AliasDecoder.decode(payload(hit),hit.recordKey)
        val own = alias.entry().copy(redirect=alias.redirect(false),edition=dictionary.edition,contentDictionary=dictionary.id,
            navigationKind=alias.sourceKind,navigationLanguage=hit.language.takeIf { alias.sourceKind == "language" && it.isNotEmpty() })
        val kind = alias.targetKind ?: return@readEntryOnIo own
        // Follow only one edge. Another redirect (including a cycle) stays a compiled redirect page.
        val targetKey = "${blobKinds.indexOf(kind)+1}\t${alias.targetKey}"
        helper.readableDatabase.rawQuery("SELECT $hitColumns FROM word_choices WHERE dictionary=? AND record_key=? LIMIT 1",arrayOf(hit.dictionary,targetKey)).use { c ->
            if (c.moveToFirst()) {
                val nextHit = hit(c)
                val next = AliasDecoder.decode(payload(nextHit),nextHit.recordKey)
                require(next.sourceNamespace == alias.targetNamespace && next.sourceTitle == alias.targetTitle && next.sourceKind == kind)
                return@readEntryOnIo next.entry().copy(redirect=alias.redirect(true),edition=dictionary.edition,contentDictionary=dictionary.id,
                    navigationKind=next.sourceKind,navigationLanguage=hit.language.takeIf { hit.kind == "language" && next.sourceKind == "language" && it.isNotEmpty() })
            }
        }
        if (dictionary.edition.isEmpty()) return@readEntryOnIo own
        val targetDictionary = if (kind == "language") {
            if (hit.kind != "language") return@readEntryOnIo own
            dictionaries.firstOrNull { it.id == hit.contextDictionary && it.edition == dictionary.edition && it.kind == kind }
        } else dictionaries.singleOrNull { it.edition == dictionary.edition && it.kind == kind }
        targetDictionary ?: return@readEntryOnIo own
        helper.readableDatabase.rawQuery("SELECT $hitColumns FROM word_choices WHERE dictionary=? AND title=substr(?,2) LIMIT 1",arrayOf(targetDictionary.id,sqlText(alias.targetKey))).use { c ->
            if (c.moveToFirst()) plain(hit(c)).copy(redirect=alias.redirect(true)) else own
        }
    }
    suspend fun savedWord(word: SavedWord): WordHit? = withContext(Dispatchers.IO) {
        if (word.dictionary == null) return@withContext legacySelection(word.title,word.language,word.kind,word.edition.orEmpty())
        helper.readableDatabase.rawQuery("SELECT $hitColumns FROM word_choices WHERE dictionary=? AND record_key=substr(?,2) AND COALESCE(context_dictionary,'')=? LIMIT 1",
            arrayOf(word.dictionary,sqlText(word.recordKey.orEmpty()),word.contextDictionary.orEmpty())).use { c -> if(c.moveToFirst()) hit(c) else null }
    }
    suspend fun link(target: EntryLink, entry: Entry): WordHit? = withContext(Dispatchers.IO) {
        val key = if (target.targetFragment == null) target.title.replace('_',' ') else target.title
        if (entry.edition.isEmpty()) {
            val dictionary = entry.origin?.dictionary ?: return@withContext null
            return@withContext helper.readableDatabase.rawQuery("SELECT $hitColumns FROM word_choices WHERE normalized=substr(?,2) AND dictionary=? AND kind=? ORDER BY CASE WHEN title=substr(?,2) THEN 0 ELSE 1 END LIMIT 1",
                arrayOf(sqlText(foldSearchKey(key)),dictionary,entry.navigationKind,sqlText(key))).use { c -> if(c.moveToFirst()) hit(c) else null }
        }
        if (entry.navigationKind == "language" && entry.navigationLanguage.isNullOrEmpty()) return@withContext null
        // A language heading names an owner only when that owner is installed in this edition.
        // Other fragments remain ordinary within-owner section destinations.
        val fragment = target.fragment.replace('_', ' ')
        val explicitOwner = entry.navigationKind == "language" && dictionaries.any {
            it.edition == entry.edition && it.kind == "language" && it.language == fragment
        }
        val linkLanguage = if (explicitOwner) fragment else entry.navigationLanguage.orEmpty()
        val current = helper.readableDatabase.rawQuery("SELECT $hitColumns FROM word_choices WHERE normalized=substr(?,2) AND edition=? AND kind=? AND (substr(?,2)='' OR language=substr(?,2)) ORDER BY CASE WHEN title=substr(?,2) THEN 0 ELSE 1 END LIMIT 1",
            arrayOf(sqlText(foldSearchKey(key)),entry.edition,entry.navigationKind,sqlText(linkLanguage),sqlText(linkLanguage),sqlText(key))).use { c -> if(c.moveToFirst()) hit(c) else null }
        if (current != null || explicitOwner || entry.kind != "language" || entry.navigationKind != "language" || entry.redirect != null)
            return@withContext current
        // Ownerless pages are installed separately. Only an exact ordinary target in
        // this edition may follow a current-owner miss; aliases keep their own route.
        val unclassified = dictionaries.singleOrNull {
            it.edition == entry.edition && it.kind == "language" && it.language == "Unclassified"
        } ?: return@withContext null
        helper.readableDatabase.rawQuery("SELECT $hitColumns FROM word_choices WHERE dictionary=? AND kind='language' AND title=substr(?,2) LIMIT 2",
            arrayOf(unclassified.id,sqlText(key))).use { c ->
            if (!c.moveToFirst()) null else hit(c).takeUnless { c.moveToNext() }
        }
    }
    fun rememberWord(hit:WordHit) { prefs.edit().putString("lastTitle",hit.title).putString("lastLanguage",hit.language)
        .putString("lastDictionary",hit.dictionary).putString("lastRecordKey",hit.recordKey).putString("lastContextDictionary",hit.contextDictionary).putString("lastEdition",hit.edition).apply() }
    fun remove(id: String) = operation("Removing dictionary") {
        val db = helper.writableDatabase
        var failure: Throwable? = null
        db.beginTransaction()
        try {
            db.delete("words", "dictionary=?", arrayOf(id))
            db.delete("dictionaries", "id=?", arrayOf(id))
            db.setTransactionSuccessful()
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            finishDictionaryRemoval(failure, { db.endTransaction() },
                registered = { committedDictionaryRegistration(db, id) },
                removeFile = {
                    val payload = File(directory, "$id.wikblb")
                    if (!payload.delete() && payload.exists()) throw IOException("Cannot remove dictionary payload")
                },
                refresh = { refresh() })
        }
    }
}
private fun compareUtf8(a: ByteArray,b: ByteArray): Int { for(i in 0 until minOf(a.size,b.size)){val d=(a[i].toInt() and 255)-(b[i].toInt() and 255);if(d!=0)return d};return a.size-b.size }
internal class CountingInput(input: InputStream): FilterInputStream(input) {
    var position=0L;private set
    override fun read():Int = super.read().also { if(it>=0)position++ }
    fun bytes(n:Int):ByteArray {
        val b=ByteArray(n)
        var offset=0
        while(offset<n) {
            val count=`in`.read(b,offset,n-offset)
            require(count>=0) { "Truncated dictionary" }
            if(count==0) {
                val x=read()
                require(x>=0) { "Truncated dictionary" }
                b[offset++]=x.toByte()
            } else {
                position+=count
                offset+=count
            }
        }
        return b
    }
    fun nul():String { val b=ByteArrayOutputStream();while(true){val x=read();require(x>=0 && b.size()<65536){"Invalid title"};if(x==0)break;b.write(x)};return b.toByteArray().decodeToString(throwOnInvalidSequence=true) }
    fun varuint():Long { var value=0L;var shift=0;while(true){val x=read();require(x>=0 && shift<63);value=value or ((x and 127).toLong() shl shift);if(x and 128==0){require(shift==0||x!=0);return value};shift+=7} }
    fun skipFully(n:Long){var left=n;while(left>0){val skipped=`in`.skip(left);if(skipped==0L){require(read()>=0);left--}else{position+=skipped;left-=skipped}}}
}
