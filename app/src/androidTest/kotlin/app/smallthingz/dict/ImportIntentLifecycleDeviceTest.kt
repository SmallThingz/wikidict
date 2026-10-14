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
                scenario = ActivityScenario.launch(intent(action, firstUri))
                assertEquals(1, call("await-open", first).getInt("opens"))
                assertEquals(1, call("state", first).getInt("heldWriters"))
                scenario.recreate()
                scenario.onActivity { activity ->
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
                    activity.startActivity(intent(action, secondUri).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP))
                }
                assertEquals(1, call("await-open", second).getInt("opens"))
                instrumentation.waitForIdleSync()
                scenario.recreate()
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
}
