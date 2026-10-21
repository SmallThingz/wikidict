package app.smallthingz.dict

import android.content.ClipData
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ImportIntentLifecycleDeviceTest {
    @Test fun malformedPresentationRecordsNeverPublishAndPreserveInstalledLibrary() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val library = LibraryStore.get(context)
        val scopeField = LibraryStore::class.java.getDeclaredField("scope").apply { isAccessible = true }
        val scopeJob = (scopeField.get(library) as CoroutineScope).coroutineContext[Job]!!
        withTimeout(10_000) { scopeJob.children.toList().joinAll() }
        assertNull(library.busy)
        val valid = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            instrumentation.context.assets.open("compiled-alias-targets.wikblb").use { it.readBytes() }
        }
        val edition = "recordcheck" + UUID.randomUUID().toString().replace("-", "").take(8) + "wiktionary-20261001"
        val filename = edition + "-ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"
        fun digest(bytes: ByteArray) = java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }
        val id = digest(valid) + "-" + edition
        val beforeIds = library.dictionaries.map { it.id }.toSet()
        assertFalse(beforeIds.contains(id))
        val directory = java.io.File(context.filesDir, "dictionaries")
        val prefs = context.getSharedPreferences("library", Context.MODE_PRIVATE)
        val ownerKeys = setOf("downloadId", "downloadUrl", "downloadLabel", "downloadBytes", "downloadHash")
        suspend fun files() = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            directory.listFiles().orEmpty().map { it.name }.toSet()
        }
        suspend fun owners() = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            prefs.all.filterKeys { it in ownerKeys }
        }
        try {
            library.importFile(name = { filename }) { java.io.ByteArrayInputStream(valid) }.join()
            assertNull(library.error)
            val installed = library.dictionaries.toList()
            val hit = requireNotNull(library.exact("animus", "English", edition))
            val entry = library.read(hit)
            val expectedFiles = files()
            val expectedOwner = owners()
            // Complete valid transport envelopes, with ordinary truncated DPR2 records.
            // The real import hashes every byte; no checksum bypass/fault injection.
            for (kind in 1..7) for (record in listOf("DPR2".toByteArray(), "DPR2".toByteArray() + byteArrayOf(0))) {
                val bytes = java.io.ByteArrayOutputStream().apply {
                    write("WIKBLB08".toByteArray()); write(kind)
                    if (kind == 1) { write("en".toByteArray()); write(0); write("English".toByteArray()); write(0) }
                    write("broken".toByteArray()); write(0); write(record.size); write(record)
                }.toByteArray()
                val badId = digest(bytes)
                library.importFile { java.io.ByteArrayInputStream(bytes) }.join()
                assertNotNull("Kind " + kind + " must reject incomplete presentation", library.error)
                assertEquals(installed, library.dictionaries.toList())
                assertEquals(expectedFiles, files())
                assertEquals(expectedOwner, owners())
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    android.database.sqlite.SQLiteDatabase.openDatabase(context.getDatabasePath("library.db").path, null,
                        android.database.sqlite.SQLiteDatabase.OPEN_READONLY).use { db ->
                        for ((table, key) in listOf("dictionaries" to "id", "words" to "dictionary")) {
                            db.rawQuery("SELECT COUNT(*) FROM $table WHERE $key=?", arrayOf(badId)).use { cursor ->
                                assertTrue(cursor.moveToFirst()); assertEquals(0L, cursor.getLong(0))
                            }
                        }
                    }
                    assertArrayEquals(valid, java.io.File(directory, "$id.wikblb").readBytes())
                }
                assertEquals(entry, library.read(hit))
            }
        } finally {
            library.remove(id).join()
            assertEquals(beforeIds, library.dictionaries.map { it.id }.toSet())
        }
    }

    @Test fun identicalReimportRepairsMissingPayloadWithoutReplacingRowsOrDownloadOwner() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val library = LibraryStore.get(context)
        val scopeField = LibraryStore::class.java.getDeclaredField("scope").apply { isAccessible = true }
        val scopeJob = (scopeField.get(library) as CoroutineScope).coroutineContext[Job]!!
        withTimeout(10_000) { scopeJob.children.toList().joinAll() }
        assertNull(library.busy)
        val bytes = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            instrumentation.context.assets.open("compiled-alias-targets.wikblb").use { it.readBytes() }
        }
        val hash = java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        val edition = "missingfile" + UUID.randomUUID().toString().replace("-", "").take(8) + "wiktionary-20261001"
        val filename = edition + "-ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"
        val id = "$hash-$edition"
        val beforeIds = library.dictionaries.map { it.id }.toSet()
        assertFalse(beforeIds.contains(id))
        val directory = java.io.File(context.filesDir, "dictionaries")
        val payload = java.io.File(directory, "$id.wikblb")
        val prefs = context.getSharedPreferences("library", Context.MODE_PRIVATE)
        val keys = setOf("downloadId", "downloadUrl", "downloadLabel", "downloadBytes", "downloadHash")
        suspend fun downloadRecord() = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            prefs.all.filterKeys { it in keys }
        }
        val originalDownload = downloadRecord()
        assertEquals("A real retained download must not enter this fixture", -1L, prefs.getLong("downloadId", -1))
        val markerId = 900_000_000_001L
        suspend fun rows(): List<List<String>> = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            android.database.sqlite.SQLiteDatabase.openDatabase(context.getDatabasePath("library.db").path, null,
                android.database.sqlite.SQLiteDatabase.OPEN_READONLY).use { db ->
                buildList {
                    for ((table, key) in listOf("dictionaries" to "id", "words" to "dictionary")) {
                        db.rawQuery("SELECT rowid,* FROM $table WHERE $key=? ORDER BY rowid", arrayOf(id)).use { cursor ->
                            while (cursor.moveToNext()) add(buildList {
                                add(table)
                                for (column in 0 until cursor.columnCount) add(when (cursor.getType(column)) {
                                    android.database.Cursor.FIELD_TYPE_NULL -> "null"
                                    android.database.Cursor.FIELD_TYPE_INTEGER -> "I:" + cursor.getLong(column)
                                    android.database.Cursor.FIELD_TYPE_FLOAT -> "F:" + java.lang.Double.doubleToLongBits(cursor.getDouble(column))
                                    android.database.Cursor.FIELD_TYPE_STRING -> "S:" + cursor.getString(column)
                                    else -> "B:" + cursor.getBlob(column).joinToString("") { "%02x".format(it) }
                                })
                            })
                        }
                    }
                }
            }
        }
        suspend fun parts() = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            directory.listFiles().orEmpty().filter { it.extension == "part" }.map { it.name }.toSet()
        }
        val originalParts = parts()
        try {
            library.importFile(name = { filename }) { java.io.ByteArrayInputStream(bytes) }.join()
            assertNull(library.error)
            val registered = rows()
            assertTrue(registered.size > 1)
            val hit = requireNotNull(library.exact("animus", "English", edition))
            assertEquals(id, hit.dictionary)
            val entry = library.read(hit)
            val installedBytes = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { payload.readBytes() }
            assertArrayEquals(bytes, installedBytes)
            library.importFile(name = { filename }) { java.io.ByteArrayInputStream(bytes) }.join()
            assertNull(library.error)
            assertEquals(registered, rows())

            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { assertTrue(payload.delete()) }
            try { library.read(hit); fail("Missing payload must not appear readable") }
            catch (expected: java.io.IOException) { /* The registered rows remain available for repair. */ }
            assertEquals(registered, rows())

            // Fault injection after the real import digest: exercise validation on the
            // same-ID repair branch, rather than creating a different dictionary ID.
            library.importFile(name = {
                val staged = directory.listFiles().orEmpty().filter { it.extension == "part" && it.name !in originalParts }
                assertEquals(1, staged.size)
                staged.single().writeBytes(bytes.copyOf(bytes.size - 1))
                filename
            }) { java.io.ByteArrayInputStream(bytes) }.join()
            assertNotNull(library.error)
            assertEquals(registered, rows())
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { assertFalse(payload.exists()) }
            assertEquals(originalParts, parts())

            // Independent retained-owner metadata must survive import/repair; this
            // fixture does not enqueue or claim a real DownloadManager request.
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                assertTrue(prefs.edit().putLong("downloadId", markerId).putString("downloadUrl", "https://example.invalid/new-owner")
                    .putString("downloadLabel", "Independent owner").putLong("downloadBytes", 123)
                    .putString("downloadHash", hash).commit())
            }
            val independentOwner = downloadRecord()
            library.importFile(name = { filename }) { java.io.ByteArrayInputStream(bytes) }.join()
            assertNull(library.error)
            assertEquals(registered, rows())
            assertEquals(independentOwner, downloadRecord())
            assertEquals(hit, library.exact("animus", "English", edition))
            assertEquals(entry, library.read(hit))
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { assertArrayEquals(bytes, payload.readBytes()) }
            assertEquals(originalParts, parts())
        } finally {
            library.remove(id).join()
            kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable + kotlinx.coroutines.Dispatchers.IO) {
                // Never restore this fixture's old snapshot over a newer owner.
                if (prefs.getLong("downloadId", -1) == markerId) {
                    val edit = prefs.edit()
                    keys.forEach { edit.remove(it) }
                    originalDownload.forEach { (key, value) -> when (value) {
                        is Long -> edit.putLong(key, value)
                        is String -> edit.putString(key, value)
                        else -> error("Unexpected retained download field type")
                    } }
                    assertTrue(edit.commit())
                }
            }
            assertEquals(beforeIds, library.dictionaries.map { it.id }.toSet())
        }
    }

    @Test fun recreationDoesNotReplayConsumedImportsAndNewIntentsStillImport() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertEquals("A retained real download must not enter this fixture", -1L,
            context.getSharedPreferences("library", Context.MODE_PRIVATE).getLong("downloadId", -1))
        val library = LibraryStore.get(context)
        // Joining accepted children catches a duplicate even before Dispatchers.IO schedules it.
        // Keep all joins off Main: import cleanup explicitly dispatches back to Main.
        val scopeField = LibraryStore::class.java.getDeclaredField("scope").apply { isAccessible = true }
        val scopeJob = (scopeField.get(library) as CoroutineScope).coroutineContext[Job]!!
        fun children() = scopeJob.children.toList()
        fun join(jobs: List<Job>) = runBlocking { withTimeout(10_000) { jobs.joinAll() } }
        join(children())
        assertFalse(library.hasRetainedDownload)
        val before = library.dictionaries.map { it.id }
        val provider = instrumentation.context.packageManager.getProviderInfo(
            ComponentName(instrumentation.context, ImportLifecycleProvider::class.java), 0)
        val base = Uri.parse("content://${provider.authority}")
        val resolver = context.contentResolver
        fun call(method: String, token: String) = requireNotNull(resolver.call(base, method, token, null))
        fun intent(action: String, uri: Uri) = Intent(context, MainActivity::class.java).apply {
            this.action = action
            if (action == Intent.ACTION_VIEW) setDataAndType(uri, "application/x-wikblb")
            else { type = "application/x-wikblb"; putExtra(Intent.EXTRA_STREAM, uri) }
            clipData = ClipData.newRawUri("Synthetic dictionary", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        fun cancelReleaseAndDrain(token: String) {
            val accepted = children()
            library.cancel()
            // Ensure cancellation has run while the provider is still holding the read open.
            join(children().filter { it !in accepted })
            call("release", token)
            join(accepted + children())
            assertEquals(0, call("state", token).getInt("heldWriters"))
        }
        for (action in listOf(Intent.ACTION_VIEW, Intent.ACTION_SEND)) {
            val first = UUID.randomUUID().toString()
            val second = UUID.randomUUID().toString()
            call("prepare", first); call("prepare", second)
            val firstUri = base.buildUpon().appendPath(first).build()
            val secondUri = base.buildUpon().appendPath(second).build()
            var scenario: ActivityScenario<MainActivity>? = null
            try {
                scenario = ActivityScenario.launch(intent(action, firstUri), physicalActivityLaunchOptions())
                scenario.onActivity { assertPhysicalActivity(it) }
                assertEquals(1, call("await-open", first).getInt("opens"))
                assertEquals(1, call("state", first).getInt("heldWriters"))
                scenario.recreate()
                scenario.onActivity { activity ->
                    assertPhysicalActivity(activity)
                    assertEquals(action, activity.intent.action)
                    assertTrue(activity.intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
                    assertEquals(firstUri, activity.intent.clipData!!.getItemAt(0).uri)
                    if (action == Intent.ACTION_VIEW) assertEquals(firstUri, activity.intent.data)
                    else assertEquals(firstUri, activity.intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
                }
                cancelReleaseAndDrain(first)
                assertEquals("Recreation must not queue the consumed $action import", 1,
                    call("state", first).getInt("opens"))

                // Use the real singleTop delivery path, not a direct call to handle/onNewIntent.
                scenario.onActivity { activity ->
                    assertPhysicalActivity(activity)
                    activity.startActivity(intent(action, secondUri).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), physicalActivityLaunchOptions())
                }
                assertEquals(1, call("await-open", second).getInt("opens"))
                instrumentation.waitForIdleSync()
                scenario.recreate()
                scenario.onActivity { assertPhysicalActivity(it) }
                cancelReleaseAndDrain(second)
                assertEquals(1, call("state", second).getInt("opens"))
                assertEquals("The original launch URI must remain consumed", 1,
                    call("state", first).getInt("opens"))
                assertEquals(before, library.dictionaries.map { it.id })
            } finally {
                try {
                    library.cancel()
                    call("release", first); call("release", second)
                    join(children())
                } finally {
                    try { scenario?.close() }
                    finally { call("remove", first); call("remove", second) }
                }
            }
        }
    }

    @Test fun cancelClosesOwnedProviderReadBeforeWriterReleaseAndAllowsNextOperation() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertEquals("A retained real download must not enter this fixture", -1L,
            context.getSharedPreferences("library", Context.MODE_PRIVATE).getLong("downloadId", -1))
        val library = LibraryStore.get(context)
        val scopeField = LibraryStore::class.java.getDeclaredField("scope").apply { isAccessible = true }
        val scopeJob = (scopeField.get(library) as CoroutineScope).coroutineContext[Job]!!
        fun children() = scopeJob.children.toList()
        fun join(jobs: List<Job>) = runBlocking { withTimeout(10_000) { jobs.joinAll() } }
        join(children())
        assertFalse(library.hasRetainedDownload)
        val before = library.dictionaries.toList()
        val directory = java.io.File(context.filesDir, "dictionaries")
        fun parts() = directory.listFiles().orEmpty().filter { it.extension == "part" }.map { it.name }.toSet()
        val partsBefore = parts()
        val absentId = "cancelled-import-" + UUID.randomUUID()
        assertTrue(before.none { it.id == absentId })
        assertFalse(java.io.File(directory, "$absentId.wikblb").exists())

        val provider = instrumentation.context.packageManager.getProviderInfo(
            ComponentName(instrumentation.context, ImportLifecycleProvider::class.java), 0)
        val base = Uri.parse("content://${provider.authority}")
        val resolver = context.contentResolver
        val token = UUID.randomUUID().toString()
        fun call(method: String) = requireNotNull(resolver.call(base, method, token, null))
        val uri = base.buildUpon().appendPath(token).build()
        val secondReadEntered = java.util.concurrent.CountDownLatch(1)
        val firstReadBytes = java.util.concurrent.atomic.AtomicInteger(-1)
        val secondReadReturned = java.util.concurrent.atomic.AtomicBoolean(false)
        val closeCalls = java.util.concurrent.atomic.AtomicInteger(0)
        val closeOnMain = java.util.concurrent.atomic.AtomicBoolean(false)
        var accepted: Job? = null
        call("prepare")
        try {
            accepted = library.importFile {
                val source = requireNotNull(resolver.openInputStream(uri))
                object : java.io.FilterInputStream(source) {
                    private var reads = 0
                    override fun read(buffer: ByteArray): Int = read(buffer, 0, buffer.size)
                    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                        val number = ++reads
                        // The real provider supplies one byte then holds its pipe open.
                        // Signal after the loop's ensureActive, then delegate unconditionally:
                        // the old implementation cannot skip this pending read on cancellation.
                        if (number == 2) secondReadEntered.countDown()
                        return try {
                            super.read(buffer, offset, length).also {
                                if (number == 1) firstReadBytes.set(it)
                            }
                        } finally { if (number == 2) secondReadReturned.set(true) }
                    }
                    override fun close() {
                        closeCalls.incrementAndGet()
                        if (Thread.currentThread() === android.os.Looper.getMainLooper().thread) closeOnMain.set(true)
                        super.close()
                    }
                }
            }
            assertTrue("Import must enter the second real provider read",
                secondReadEntered.await(10, java.util.concurrent.TimeUnit.SECONDS))
            assertEquals(1, firstReadBytes.get())
            assertFalse("The provider still holds the read open", secondReadReturned.get())
            assertEquals(1, call("state").getInt("heldWriters"))

            library.cancel()
            join(listOf(checkNotNull(accepted)) + children())
            assertTrue(checkNotNull(accepted).isCancelled)
            assertTrue("The read child must finish before import cleanup returns", secondReadReturned.get())
            assertEquals("Close the exact owned stream once", 1, closeCalls.get())
            assertFalse("Do not close provider I/O on the UI thread", closeOnMain.get())
            assertNull(library.busy)
            assertNull("A close-induced I/O error must remain cancellation", library.error)
            assertEquals(partsBefore, parts())
            assertEquals(before, library.dictionaries)
            assertEquals("Cancellation must not depend on releasing the provider writer",
                1, call("state").getInt("heldWriters"))

            // This real mutex-owned transaction must complete while the original pipe
            // writer remains held. Its fresh absent ID cannot remove user content.
            val next = library.remove(absentId)
            join(listOf(next) + children())
            assertFalse(next.isCancelled)
            assertNull(library.busy)
            assertNull(library.error)
            assertEquals(before, library.dictionaries)
            assertEquals(partsBefore, parts())
            assertFalse(java.io.File(directory, "$absentId.wikblb").exists())
            assertEquals(1, call("state").getInt("heldWriters"))
        } finally {
            try {
                library.cancel()
                try { call("release") }
                finally { join(listOfNotNull(accepted) + children()) }
            } finally { call("remove") }
        }
    }

    @Test fun pendingStartupImportsSurviveRetainedOwnerAndFailedOpen() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val application = context.applicationContext as android.app.Application
        val stores = ReaderStores(LibraryStore.get(context), LearningStore.get(context))
        val provider = instrumentation.context.packageManager.getProviderInfo(
            ComponentName(instrumentation.context, ImportLifecycleProvider::class.java), 0)
        val base = Uri.parse("content://${provider.authority}")
        val tokens = List(4) { UUID.randomUUID().toString() }
        fun call(method: String, token: String) = requireNotNull(context.contentResolver.call(base, method, token, null))
        val saved = androidx.lifecycle.SavedStateHandle()
        val retained = androidx.lifecycle.ViewModelStore()
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val attempts = java.util.concurrent.atomic.AtomicInteger()
        val openedOnMain = java.util.concurrent.atomic.AtomicBoolean(false)
        lateinit var owner: ReaderStartup
        fun awaitState(predicate: () -> Boolean) = runBlocking {
            withTimeout(10_000) {
                while (true) {
                    var ready = false
                    instrumentation.runOnMainSync { ready = predicate() }
                    if (ready) break
                    kotlinx.coroutines.delay(10)
                }
            }
        }
        val scopeField = LibraryStore::class.java.getDeclaredField("scope").apply { isAccessible = true }
        val scopeJob = (scopeField.get(stores.library) as CoroutineScope).coroutineContext[Job]!!
        fun drain() = runBlocking { withTimeout(10_000) { scopeJob.children.toList().joinAll() } }
        drain()
        val before = stores.library.dictionaries.toList()
        try {
            tokens.forEach { call("prepare", it); call("release", it) }
            instrumentation.runOnMainSync {
                val factory = object : androidx.lifecycle.ViewModelProvider.Factory {
                    override fun <T : androidx.lifecycle.ViewModel> create(modelClass: Class<T>): T =
                        modelClass.cast(ReaderStartup(application, saved) {
                            if (Thread.currentThread() === android.os.Looper.getMainLooper().thread) openedOnMain.set(true)
                            if (attempts.incrementAndGet() == 1) {
                                entered.countDown()
                                check(release.await(10, java.util.concurrent.TimeUnit.SECONDS))
                                throw java.io.IOException("Controlled first open failure")
                            }
                            stores
                        })!!
                }
                owner = androidx.lifecycle.ViewModelProvider(retained, factory)[ReaderStartup::class.java]
                tokens.forEach { owner.import(base.buildUpon().appendPath(it).build()) }
                // A new Activity's provider sees the same retained pending owner.
                assertSame(owner, androidx.lifecycle.ViewModelProvider(retained, factory)[ReaderStartup::class.java])
            }
            assertTrue(entered.await(10, java.util.concurrent.TimeUnit.SECONDS))
            instrumentation.runOnMainSync {
                assertNull(owner.stores)
                assertEquals(4, saved.get<ArrayList<Uri>>("pendingImports")!!.size)
            }
            tokens.forEach { assertEquals(0, call("state", it).getInt("opens")) }
            release.countDown()
            awaitState { owner.failed }
            instrumentation.runOnMainSync {
                assertEquals(4, saved.get<ArrayList<Uri>>("pendingImports")!!.size)
                owner.retry()
            }
            awaitState { owner.stores != null }
            tokens.forEach { assertEquals(1, call("await-open", it).getInt("opens")) }
            drain()
            instrumentation.runOnMainSync {
                assertFalse(owner.failed)
                assertTrue(saved.get<ArrayList<Uri>>("pendingImports")!!.isEmpty())
                owner.retry()
            }
            assertEquals(2, attempts.get())
            assertFalse("Open stores off Main even when they are already cached", openedOnMain.get())
            tokens.forEach { assertEquals(1, call("state", it).getInt("opens")) }
            assertEquals(before, stores.library.dictionaries)
        } finally {
            release.countDown()
            instrumentation.runOnMainSync { retained.clear() }
            tokens.forEach { call("release", it) }
            drain()
            tokens.forEach { call("remove", it) }
        }
    }

    @Test fun clearingPendingStartupCancelsPublicationAndPreservesQueuedUri() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val application = context.applicationContext as android.app.Application
        val stores = ReaderStores(LibraryStore.get(context), LearningStore.get(context))
        val saved = androidx.lifecycle.SavedStateHandle()
        val retained = androidx.lifecycle.ViewModelStore()
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val returned = java.util.concurrent.CountDownLatch(1)
        val uri = Uri.parse("content://cancelled-startup.invalid/never-open")
        lateinit var owner: ReaderStartup
        lateinit var opening: Job
        try {
            instrumentation.runOnMainSync {
                owner = ReaderStartup(application, saved) {
                    entered.countDown()
                    try {
                        check(release.await(10, java.util.concurrent.TimeUnit.SECONDS))
                        stores
                    } finally { returned.countDown() }
                }
                val factory = object : androidx.lifecycle.ViewModelProvider.Factory {
                    override fun <T : androidx.lifecycle.ViewModel> create(modelClass: Class<T>): T = modelClass.cast(owner)!!
                }
                assertSame(owner, androidx.lifecycle.ViewModelProvider(retained, factory)[ReaderStartup::class.java])
                owner.import(uri)
                val field = ReaderStartup::class.java.getDeclaredField("opening").apply { isAccessible = true }
                opening = field.get(owner) as Job
            }
            assertTrue(entered.await(10, java.util.concurrent.TimeUnit.SECONDS))
            instrumentation.runOnMainSync { retained.clear() }
            release.countDown()
            assertTrue(returned.await(10, java.util.concurrent.TimeUnit.SECONDS))
            runBlocking { withTimeout(10_000) { opening.join() } }
            assertTrue(opening.isCancelled)
            instrumentation.runOnMainSync {
                assertNull(owner.stores)
                assertFalse("Lifecycle cancellation is not a startup error", owner.failed)
                assertEquals(listOf(uri), saved.get<ArrayList<Uri>>("pendingImports"))
            }
        } finally {
            release.countDown()
            instrumentation.runOnMainSync { retained.clear() }
        }
    }
}
