package app.smallthingz.dict

import android.content.ClipData
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.util.UUID

class WarmImportVisibilityDeviceTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test fun rapidImportRequestsKeepDistinctKeysAndStaleAcknowledgmentCannotConsumeTheNextRequest() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val application = instrumentation.targetContext.applicationContext as android.app.Application
        val saved = androidx.lifecycle.SavedStateHandle()
        val retained = androidx.lifecycle.ViewModelStore()
        val uri = Uri.parse("content://unopened-startup.invalid/queued-dictionary")
        fun owner(): ReaderStartup {
            val factory = object : androidx.lifecycle.ViewModelProvider.Factory {
                override fun <T : androidx.lifecycle.ViewModel> create(modelClass: Class<T>): T =
                    modelClass.cast(ReaderStartup(application, saved) { throw java.io.IOException("Controlled closed store") })!!
            }
            return androidx.lifecycle.ViewModelProvider(retained, factory)[ReaderStartup::class.java]
        }
        try {
            instrumentation.runOnMainSync {
                val firstOwner = owner()
                firstOwner.import(uri, showLibrary = true)
                val first = firstOwner.importNavigationRequest
                assertTrue(first > 0L)
                // Consume and accept again in the same Main turn, before Compose
                // can observe the intervening zero value as an effect key.
                firstOwner.consumeImportNavigation(first)
                firstOwner.import(uri, showLibrary = true)
                val second = firstOwner.importNavigationRequest
                assertTrue(second > first)
                firstOwner.consumeImportNavigation(first)
                assertEquals(second, firstOwner.importNavigationRequest)
                retained.clear()
                val restored = owner()
                assertEquals(second, restored.importNavigationRequest)
                restored.import(uri, showLibrary = true)
                assertTrue(restored.importNavigationRequest > second)
                assertEquals(listOf(uri, uri, uri), saved.get<ArrayList<Uri>>("pendingImports"))
                restored.consumeImportNavigation(second)
                assertTrue(restored.importNavigationRequest > second)
                restored.consumeImportNavigation(restored.importNavigationRequest)
                assertEquals(0L, restored.importNavigationRequest)
            }
        } finally { instrumentation.runOnMainSync { retained.clear() } }
    }

    @Test fun warmExternalImportShowsProgressAndFailureWithoutLosingReaderOrReplayingUri() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assertTrue("Use the isolated validation app", context.packageName.endsWith(".validation"))
        val prefs = context.getSharedPreferences("library", Context.MODE_PRIVATE)
        assertEquals("A real retained download must not enter this fixture", -1L, prefs.getLong("downloadId", -1))
        val library = LibraryStore.get(context)
        val learning = LearningStore.get(context)
        val scopeField = LibraryStore::class.java.getDeclaredField("scope").apply { isAccessible = true }
        val scopeJob = (scopeField.get(library) as CoroutineScope).coroutineContext[Job]!!
        suspend fun drain() { withTimeout(10_000) { scopeJob.children.toList().joinAll() } }
        drain()
        assertNull(library.busy)
        assertFalse(library.hasRetainedDownload)
        assertEquals(listOf(Catalog.DEFAULT), library.sources)
        val beforeIds = library.dictionaries.map { it.id }.toSet()
        val previousSettings = learning.data.settings
        val previousHistory = learning.data.history
        val lastKeys = listOf("lastTitle", "lastLanguage", "lastDictionary", "lastRecordKey", "lastContextDictionary", "lastEdition")
        val previousSelection = lastKeys.associateWith { prefs.getString(it, null) }
        val bytes = withContext(Dispatchers.IO) {
            instrumentation.context.assets.open("compiled-alias-targets.wikblb").use { it.readBytes() }
        }
        val edition = "warmimport" + UUID.randomUUID().toString().replace("-", "").take(8) + "wiktionary-20261001"
        val filename = "$edition-ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"
        val hash = java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        val id = "$hash-$edition"
        assertFalse(id in beforeIds)
        val provider = instrumentation.context.packageManager.getProviderInfo(
            ComponentName(instrumentation.context, ImportLifecycleProvider::class.java), 0)
        val base = Uri.parse("content://${provider.authority}")
        val tokens = List(2) { UUID.randomUUID().toString() }
        val preparedTokens = mutableListOf<String>()
        fun call(method: String, token: String) = requireNotNull(context.contentResolver.call(base, method, token, null))
        fun externalIntent(action: String, token: String) = Intent(context, MainActivity::class.java).apply {
            val uri = base.buildUpon().appendPath(token).build()
            this.action = action
            if (action == Intent.ACTION_VIEW) setDataAndType(uri, "application/x-wikblb")
            else { type = "application/x-wikblb"; putExtra(Intent.EXTRA_STREAM, uri) }
            clipData = ClipData.newRawUri("Synthetic dictionary", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        fun awaitText(text: String) {
            compose.waitUntil(10_000) {
                compose.onAllNodesWithText(text).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
            }
            compose.onNodeWithText(text).assertIsDisplayed()
        }
        fun awaitReader() {
            compose.waitUntil(10_000) {
                compose.onAllNodes(hasTestTag("entry-title") and hasText("animus"))
                    .fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
            }
            compose.onNode(hasTestTag("entry-title") and hasText("animus")).assertIsDisplayed()
        }
        var scenario: ActivityScenario<MainActivity>? = null
        var primaryFailure: Throwable? = null
        try {
            instrumentation.runOnMainSync { learning.updateSettings { it.copy(historyEnabled = false) } }
            library.importFile(name = { filename }) { ByteArrayInputStream(bytes) }.join()
            assertNull(library.error)
            val hit = requireNotNull(library.exact("animus", "English", edition))
            val entry = library.read(hit)
            library.rememberWord(hit)
            instrumentation.runOnMainSync { library.removeSource(Catalog.DEFAULT) }
            drain()
            assertTrue(library.catalog.isEmpty())
            assertTrue(library.sources.isEmpty())
            scenario = ActivityScenario.launch(Intent(context, MainActivity::class.java), physicalActivityLaunchOptions())
            scenario.onActivity { assertPhysicalActivity(it) }
            awaitReader()
            for ((index, action) in listOf(Intent.ACTION_VIEW, Intent.ACTION_SEND).withIndex()) {
                val token = tokens[index]
                call("prepare", token)
                preparedTokens += token
                // The second source returns EOF immediately instead of holding a read open.
                if (index == 1) call("release", token)
                scenario.onActivity { activity ->
                    assertPhysicalActivity(activity)
                    activity.startActivity(externalIntent(action, token), physicalActivityLaunchOptions())
                }
                assertEquals(1, call("await-open", token).getInt("opens"))
                awaitText("Dictionaries")
                if (index == 0) {
                    awaitText("Importing dictionary")
                    compose.onNodeWithContentDescription("Import wikblb").assertIsNotEnabled()
                    call("release", token)
                }
                drain()
                val failure = requireNotNull(library.error)
                awaitText(failure)
                compose.onNodeWithContentDescription("Import wikblb").assertIsEnabled()
                compose.onNodeWithContentDescription("Refresh catalogues").assertIsEnabled()
                assertEquals(beforeIds + id, library.dictionaries.map { it.id }.toSet())
                assertEquals(entry, library.read(hit))
                withContext(Dispatchers.IO) {
                    assertArrayEquals(bytes, File(context.filesDir, "dictionaries/$id.wikblb").readBytes())
                }
                scenario.recreate()
                scenario.onActivity { assertPhysicalActivity(it) }
                awaitText("Dictionaries")
                drain()
                assertEquals(failure, library.error)
                awaitText(failure)
                assertEquals("Recreation must not import the consumed URI", 1, call("state", token).getInt("opens"))
                assertEquals(0, call("state", token).getInt("heldWriters"))
                if (index == 0) {
                    scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
                    compose.waitForIdle()
                    scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
                    awaitReader()
                }
            }
            // Ordinary successful import recovery; this does not exercise the document picker.
            library.importFile(name = { filename }) { ByteArrayInputStream(bytes) }.join()
            assertNull(library.error)
            awaitText("Dictionaries")
            compose.onNodeWithContentDescription("Import wikblb").assertIsEnabled()
            assertEquals(beforeIds + id, library.dictionaries.map { it.id }.toSet())
            assertEquals(entry, library.read(hit))
            assertEquals(previousHistory, learning.data.history)
        } catch (failure: Throwable) {
            primaryFailure = failure
            throw failure
        } finally {
            val cleanupFailures = mutableListOf<Throwable>()
            suspend fun cleanup(action: suspend () -> Unit) {
                try { action() } catch (failure: Throwable) { cleanupFailures += failure }
            }
            preparedTokens.forEach { token -> cleanup { call("release", token) } }
            cleanup { drain() }
            cleanup { scenario?.close() }
            cleanup { withTimeout(10_000) { library.remove(id).join() } }
            cleanup {
                instrumentation.runOnMainSync {
                    if (Catalog.DEFAULT !in library.sources) library.addSource(Catalog.DEFAULT)
                    learning.updateSettings { previousSettings }
                }
            }
            cleanup {
                withContext(Dispatchers.IO) {
                    val edit = prefs.edit()
                    previousSelection.forEach { (key, value) -> if (value == null) edit.remove(key) else edit.putString(key, value) }
                    assertTrue(edit.commit())
                }
            }
            cleanup { assertEquals(beforeIds, library.dictionaries.map { it.id }.toSet()) }
            preparedTokens.forEach { token -> cleanup { call("remove", token) } }
            val failure = primaryFailure ?: cleanupFailures.firstOrNull()
            if (failure != null) {
                cleanupFailures.filter { it !== failure }.forEach(failure::addSuppressed)
                if (primaryFailure == null) throw failure
            }
        }
    }
}
